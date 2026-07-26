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
    // Safe: registered and removed exclusively on the main thread via NSEvent monitor API.
    nonisolated(unsafe) private var eventMonitor: Any?
    // Safe: registered and removed exclusively on the main thread via NSWorkspace.notificationCenter.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    // Captured once in popoverWillShow.
    // anchorPoint.y = window.frame.maxY — the fixed top-edge used by applyContentSize.
    // anchorPoint.x is retained for diagnostics only; NOT used for repositioning.
    // applyContentSize re-derives buttonMidX live from the button's current screen
    // position on every call — see that method for rationale (run-bot #2268).
    // nil until first show; cleared on popoverDidClose.
    private var anchorPoint: NSPoint?
    private var onWillCloseFired = false

    /// Buffered content size written while the menubar was hidden (popover shown but
    /// button off-screen). Flushed in popoverWillShow so the size is correct for the
    /// next open. Nil when no buffered size is pending.
    private var pendingContentSize: CGSize?

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

    // MARK: - Root view replacement

    /// Replaces the popover's root view with `view`.
    /// The GeometryReader size observer picks up the change automatically —
    /// no need to call `popover.show()` again.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Status item image

    /// Updates the status-bar button image.
    /// The caller is responsible for supplying an appropriately sized, template-mode
    /// `NSImage`. `MBKPopoverController` does not resize or retemplate the image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Auto-hide menubar guard

    /// Returns true when the macOS auto-hide menubar is currently hidden (slid off-screen).
    ///
    /// When hidden, the status item button window slides above the top edge of the screen:
    /// button.window?.frame.maxY > screen.frame.height, or the button's screen drops to nil.
    /// Writing contentSize in this state causes AppKit to re-run full anchor geometry
    /// against the off-screen button position, collapsing the popover x-origin to 0 —
    /// the open-time side-jump. Guard both contentSize writes with this.
    ///
    /// WHY > and not >=:
    /// buttonY == screenH is the normal resting position of the status button window
    /// (flush with the screen top edge). Only buttonY > screenH means the menubar has
    /// actually slid off-screen in auto-hide mode. Using >= produced a false-positive on
    /// first open, causing the pre-show contentSize write to be skipped.
    ///
    /// screenH < 0 signals a nil screen — skip in both cases.
    /// Fix ported from commit 541c20fe (MBK example app, run-bot#2237/#2239).
    private var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let buttonScreen = button.window?.screen
        let screenH = buttonScreen.map { $0.frame.height } ?? -1
        let buttonY = button.window?.frame.maxY ?? -1
        let hidden = screenH < 0 || buttonY > screenH
        mbkLog("PopoverController", "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
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
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        // Pre-show fittingSize write — seeds contentSize before show() so AppKit
        // places the window at the correct size from the first frame.
        // GUARDED: skip if auto-hide menubar is hidden — writing contentSize
        // against an off-screen button causes the side-jump on open (#2237).
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            if isMenuBarHidden {
                mbkLog("PopoverController", "openPopover -- menubar hidden, SKIP pre-show contentSize write (\(fitting.width),\(fitting.height))")
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
        let pw = panelWindow
        let pwChildren = pw?.childWindows ?? []
        return !pwChildren.isEmpty
    }

    private func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else {
            mbkLog("PopoverController", "onWillClose already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    private func forceClose() {
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose -- closing child #\(child.windowNumber)")
                pw.removeChildWindow(child)
                child.close()
            }
        } else {
            mbkLog("PopoverController", "forceClose -- no panelWindow found")
        }
        mbkLog("PopoverController", "forceClose -- calling performClose")
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

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
                        .onChange(of: geo.size) { [weak self] _, newSize in
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        )
    }

    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }
        guard popover.isShown,
              let window = hostingController.view.window,
              let anchor = anchorPoint else {
            // Not shown — bare write, no window to reposition.
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        // When the auto-hide menubar is hidden the status item button is off-screen.
        // Writing contentSize to a shown NSPopover causes AppKit to re-run its full
        // anchor geometry against the off-screen button position, which collapses the
        // popover window's x-origin to 0 — the window side-jumps even though we never
        // call setFrameOrigin ourselves (run-bot #2265).
        //
        // Fix: buffer the pending size and skip BOTH the contentSize write AND
        // setFrameOrigin. The buffer is flushed in popoverWillShow on the next open
        // so the popover starts at the correct size.
        if isMenuBarHidden {
            pendingContentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, BUFFERED (\(clamped.width),\(clamped.height)) SKIP write+reposition")
            return
        }

        // Always write contentSize so the popover tracks SwiftUI content size correctly.
        popover.contentSize = clamped

        // Re-center the window by computing buttonMidX LIVE from the button's
        // current screen position on every call.
        //
        // WHY NOT anchor.x:
        //   anchorPoint.x is captured once at show-time (window.frame.midX in
        //   popoverWillShow). In the MBK example app the button never moves, so
        //   the captured x stays valid. In RunBot, AppKit repositions the popover
        //   window on every content-width change — this shifts the button window's
        //   frame.minX, making the stale anchor.x wrong. Using it places the
        //   window off-centre and the NSPopover arrow side-jumps (run-bot #2268).
        //
        // WHY anchor.y IS STILL CORRECT:
        //   The top edge (window.frame.maxY) does not change during a session —
        //   height changes shrink/grow the window downward only. anchor.y remains
        //   accurate for the full session.
        //
        // buttonMidX = button window's screen-space left edge + button's local midX.
        // This gives the screen-space centre of the status item button regardless of
        // how many prior width changes have shifted the popover window.
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController",
                   "applyContentSize -- no button/buttonWin, WRITE only (\(clamped.width),\(clamped.height))")
            return
        }
        let buttonMidX = buttonWin.frame.minX + button.frame.midX
        let newOrigin = NSPoint(
            x: buttonMidX - window.frame.width / 2,
            y: anchor.y - window.frame.height
        )
        window.setFrameOrigin(newOrigin)
        mbkLog("PopoverController",
               "applyContentSize -- WRITE+REPOSITION (\(clamped.width),\(clamped.height)) buttonMidX=\(buttonMidX) w=\(window.frame.width) origin=\(newOrigin)")
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
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
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
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
                        if hasSheet {
                            mbkLog("PopoverController", "event monitor -- sheet overlay, force-closing")
                            self.forceClose()
                        } else {
                            mbkLog("PopoverController", "event monitor -- picker/alert overlay, ignoring outside click")
                        }
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
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (anchor skipped)")
            return
        }

        // Flush any size buffered while the menubar was hidden.
        // Do this BEFORE capturing anchorPoint so AppKit uses the correct size
        // when computing the show-time window frame.
        if let pending = pendingContentSize {
            popover.contentSize = pending
            mbkLog("PopoverController", "popoverWillShow -- flushed pendingContentSize (\(pending.width),\(pending.height))")
            pendingContentSize = nil
        }

        // anchor.y = window.frame.maxY — the fixed top-edge used for all
        // setFrameOrigin calls in applyContentSize. Stable for the session
        // because AppKit never moves the window vertically on width changes.
        //
        // anchor.x is captured here for diagnostics only. applyContentSize
        // re-derives buttonMidX live from the button's current screen position
        // on every call — handling apps like RunBot where AppKit shifts the
        // popover window on content-width changes (run-bot issue #2268).
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController",
               "popoverWillShow -- anchor=\(anchorPoint!) win=\(window.frame) #\(window.windowNumber)")
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
        anchorPoint = nil
        pendingContentSize = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
