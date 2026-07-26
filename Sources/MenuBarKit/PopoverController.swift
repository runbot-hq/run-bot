// PopoverController.swift
// MenuBarKit

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject, MBKPopoverControllerProtocol {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private var rootView: AnyView

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) private var eventMonitor: Any?
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// Captured once in popoverWillShow: the window's maxY (top edge).
    private var anchorTopY: CGFloat?

    /// The last origin.x written while the menubar was visible.
    private var lastVisibleOriginX: CGFloat?

    /// Captured once when the menubar first hides.
    /// window.frame.height - popover.contentSize.height at that moment.
    private var hiddenModeChromeHeight: CGFloat?

    /// Captured once when the menubar first hides.
    /// window.frame.width - popover.contentSize.width at that moment.
    private var hiddenModeChromeWidth: CGFloat?

    private var onWillCloseFired = false

    /// Full desired content size to flush via NSPopover when the menubar reappears.
    private var pendingContentSize: CGSize?

    nonisolated(unsafe) private var menubarPollTimer: Timer?

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rootView = AnyView(rootView)
    }

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Auto-hide menubar guard

    private var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let screenH = button.window?.screen.map { $0.frame.height } ?? -1
        let buttonY = button.window?.frame.maxY ?? -1
        let hidden = screenH < 0 || buttonY > screenH
        mbkLog("PopoverController", "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
    }

    // MARK: - Menubar poll timer

    private func startMenubarPollTimer() {
        guard menubarPollTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.menubarPollTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menubarPollTimer = timer
        mbkLog("PopoverController", "menubarPollTimer started")
    }

    private func stopMenubarPollTimer() {
        guard menubarPollTimer != nil else { return }
        menubarPollTimer?.invalidate()
        menubarPollTimer = nil
        mbkLog("PopoverController", "menubarPollTimer stopped")
    }

    private func menubarPollTick() {
        guard popover.isShown,
              let pending = pendingContentSize,
              let window = hostingController.view.window,
              let topY = anchorTopY,
              let button = statusItem.button,
              let buttonWin = button.window else {
            stopMenubarPollTimer()
            return
        }
        let screenH = buttonWin.screen.map { $0.frame.height } ?? -1
        let buttonY = buttonWin.frame.maxY
        guard screenH >= 0, buttonY <= screenH else { return }

        stopMenubarPollTimer()
        hiddenModeChromeHeight = nil
        hiddenModeChromeWidth = nil
        pendingContentSize = nil
        popover.contentSize = pending
        let buttonMidX = buttonWin.frame.minX + button.frame.midX
        let newOrigin = NSPoint(
            x: buttonMidX - window.frame.width / 2,
            y: topY - window.frame.height
        )
        window.setFrameOrigin(newOrigin)
        lastVisibleOriginX = newOrigin.x
        mbkLog("PopoverController",
               "menubarPollTick -- FLUSH+REPOSITION (\(pending.width),\(pending.height)) buttonMidX=\(buttonMidX) origin=\(newOrigin)")
    }

    // MARK: - Private setup helpers

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown { popover.performClose(nil) } else { openPopover() }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            if isMenuBarHidden {
                mbkLog("PopoverController", "openPopover -- menubar hidden, SKIP pre-show contentSize write")
            } else {
                popover.contentSize = clamp(fitting)
                mbkLog("PopoverController", "openPopover -- pre-show contentSize written (\(clamp(fitting).width),\(clamp(fitting).height))")
            }
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    private var hasSheetChildWindow: Bool {
        (panelWindow?.childWindows ?? []).isEmpty == false
    }

    private func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else { return }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    private func forceClose() {
        fireOnWillClose(wasForced: true)
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) { pw.removeChildWindow(child); child.close() }
        }
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) { statusItem.button?.isHighlighted = on }

    private func setupPopover() {
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    private func wrapped(_ view: AnyView) -> AnyView {
        AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] _, newSize in self?.applyContentSize(newSize) }
                        .onAppear { [weak self] in self?.applyContentSize(geo.size) }
                }
            )
        )
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(width: min(max(size.width, minWidth), maxWidth), height: min(size.height, maxHeight))
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }

        guard popover.isShown,
              let window = hostingController.view.window,
              let topY = anchorTopY else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        if isMenuBarHidden {
            // Snapshot chrome offsets once on first hidden call, while popover.contentSize
            // still reflects the last NSPopover-written size (in sync with window.frame).
            if hiddenModeChromeHeight == nil {
                hiddenModeChromeHeight = window.frame.height - popover.contentSize.height
                hiddenModeChromeWidth  = window.frame.width  - popover.contentSize.width
                mbkLog("PopoverController",
                       "applyContentSize -- snapshotted chromeH=\(hiddenModeChromeHeight!) chromeW=\(hiddenModeChromeWidth!)")
            }
            let chromeH = hiddenModeChromeHeight!
            let chromeW = hiddenModeChromeWidth!

            // Track the full desired size for the flush when the menubar reappears.
            pendingContentSize = clamped
            startMenubarPollTimer()

            let newWidth  = clamped.width  + chromeW
            let newHeight = clamped.height + chromeH
            let newOriginY = topY - newHeight
            let originX = lastVisibleOriginX ?? window.frame.origin.x
            let newFrame = NSRect(x: originX, y: newOriginY, width: newWidth, height: newHeight)

            // Skip if the frame is already correct.
            guard abs(window.frame.width  - newWidth)   > 1
               || abs(window.frame.height - newHeight)  > 1
               || abs(window.frame.origin.y - newOriginY) > 1 else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no frame change (pending=(\(clamped.width),\(clamped.height)))")
                return
            }

            window.setFrame(newFrame, display: true)
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, DIRECT FRAME (\(clamped.width),\(clamped.height)) chromeH=\(chromeH) chromeW=\(chromeW) frame=\(newFrame)")
            return
        }

        // Menubar visible — normal NSPopover path.
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }

        if menubarPollTimer != nil {
            stopMenubarPollTimer()
            hiddenModeChromeHeight = nil
            hiddenModeChromeWidth  = nil
            pendingContentSize = nil
        }

        popover.contentSize = clamped

        guard let button = statusItem.button, let buttonWin = button.window else {
            mbkLog("PopoverController", "applyContentSize -- no button/buttonWin, WRITE only (\(clamped.width),\(clamped.height))")
            return
        }
        let buttonMidX = buttonWin.frame.minX + button.frame.midX
        let newOrigin = NSPoint(x: buttonMidX - window.frame.width / 2, y: topY - window.frame.height)
        window.setFrameOrigin(newOrigin)
        lastVisibleOriginX = newOrigin.x
        mbkLog("PopoverController",
               "applyContentSize -- WRITE+REPOSITION (\(clamped.width),\(clamped.height)) buttonMidX=\(buttonMidX) w=\(window.frame.width) origin=\(newOrigin)")
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer -- overlay active, keeping popover open")
                    return
                }
                mbkLog("PopoverController", "workspace observer -- other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController",
                       "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PopoverController", "event monitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = self.hasSheetChildWindow
                        mbkLog("PopoverController", "event monitor -- hasSheet=\(hasSheet)")
                        if hasSheet { self.forceClose() }
                        else { mbkLog("PopoverController", "event monitor -- picker/alert overlay, ignoring outside click") }
                    }
                } else {
                    mbkLog("PopoverController", "event monitor -- no overlay, performClose")
                    self.popover.performClose(nil)
                }
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    deinit {
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let monitor = eventMonitor { NSEvent.removeMonitor(monitor) }
        menubarPollTimer?.invalidate()
    }
}

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (anchor skipped)")
            return
        }
        if let pending = pendingContentSize {
            popover.contentSize = pending
            mbkLog("PopoverController", "popoverWillShow -- flushed pendingContentSize (\(pending.width),\(pending.height))")
            pendingContentSize = nil
        }
        anchorTopY = window.frame.maxY
        mbkLog("PopoverController",
               "popoverWillShow -- anchorTopY=\(anchorTopY!) win=\(window.frame) #\(window.windowNumber)")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        stopMenubarPollTimer()
        anchorTopY = nil
        lastVisibleOriginX = nil
        hiddenModeChromeHeight = nil
        hiddenModeChromeWidth  = nil
        pendingContentSize = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
