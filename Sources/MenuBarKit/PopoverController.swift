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
    // anchorPoint.x = status button screen midX, captured in popoverWillShow from the
    // button's own coordinate space (buttonWindow.frame.origin.x + button.frame.midX).
    // This is more reliable than window.frame.midX which can be unsettled at the moment
    // popoverWillShow fires. anchorPoint.y is stored for completeness; applyContentSize
    // uses window.frame.maxY live instead.
    // nil = popover not yet shown this session; guards the isShown-reposition path.
    private var anchorPoint: NSPoint?
    private var onWillCloseFired = false

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
        mbkLog("PopoverController", "INIT minWidth=\(minWidth) maxWidth=\(maxWidth) maxHeight=\(maxHeight)")
    }

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        mbkLog("PopoverController", "setup -- begin")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup -- complete")
    }

    // MARK: - Root view replacement

    /// Replaces the popover's root view with `view`.
    /// The GeometryReader size observer picks up the change automatically —
    /// no need to call `popover.show()` again.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    public func setRootView(_ view: AnyView) {
        mbkLog("PopoverController", "setRootView -- replacing rootView")
        rootView = view
        guard isSetUp else {
            mbkLog("PopoverController", "setRootView -- not set up yet, skipping hostingController update")
            return
        }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView -- rootView replaced, hostingController updated")
    }

    // MARK: - Status item image

    /// Updates the status-bar button image.
    /// The caller is responsible for supplying an appropriately sized, template-mode
    /// `NSImage`. `MBKPopoverController` does not resize or retemplate the image.
    public func setStatusItemImage(_ image: NSImage) {
        mbkLog("PopoverController", "setStatusItemImage -- size=\(image.size)")
        statusItem?.button?.image = image
    }

    // MARK: - Auto-hide menubar guard

    /// Returns true when the macOS auto-hide menubar is currently hidden (slid off-screen).
    ///
    /// When hidden, the status item button window slides above the top edge of the screen:
    /// button.window?.frame.maxY >= screen.frame.height, or the button's screen drops to nil.
    /// ANY contentSize write in this state causes AppKit to re-run full anchor geometry
    /// against the off-screen button position, collapsing the popover x-origin to 0 — the
    /// side-jump / stray arrow. Guard ALL contentSize writes with this predicate.
    ///
    /// screenH < 0 signals a nil screen, which itself means hidden — skip in both cases.
    /// Fix ported from commit 541c20fe (MBK example app, run-bot#2237/#2239).
    private var isMenuBarHidden: Bool {
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "isMenuBarHidden -- no button, returning false")
            return false
        }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        let screenH = buttonScreen.map { $0.frame.height } ?? -1
        let buttonY = buttonWindow?.frame.maxY ?? -1
        let buttonWinFrame = buttonWindow?.frame ?? .zero
        let hidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH) buttonWinFrame=\(buttonWinFrame) screenIsNil=\(buttonScreen == nil)")
        return hidden
    }

    // MARK: - Private setup helpers

    private func setupStatusItem() {
        mbkLog("PopoverController", "setupStatusItem -- begin symbolName=\(symbolName)")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
            mbkLog("PopoverController", "setupStatusItem -- button frame=\(button.frame) bounds=\(button.bounds)")
        } else {
            mbkLog("PopoverController", "setupStatusItem -- WARNING: no button on statusItem")
        }
        mbkLog("PopoverController", "setupStatusItem -- complete")
    }

    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown {
            mbkLog("PopoverController", "togglePopover -- calling performClose")
            popover.performClose(nil)
        } else {
            mbkLog("PopoverController", "togglePopover -- calling openPopover")
            openPopover()
        }
    }

    private func openPopover() {
        mbkLog("PopoverController", "openPopover -- BEGIN")
        guard let button = statusItem.button else {
            mbkLog("PopoverController", "openPopover -- ABORT: no statusItem button")
            return
        }
        let buttonFrame = button.frame
        let buttonBounds = button.bounds
        let buttonWinFrame = button.window?.frame ?? .zero
        mbkLog("PopoverController",
               "openPopover -- button.frame=\(buttonFrame) button.bounds=\(buttonBounds) button.window.frame=\(buttonWinFrame)")

        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "openPopover -- onWillShow returned")

        // Pre-show fittingSize write — seeds contentSize before show() so AppKit
        // places the window at the correct size from the first frame.
        // GUARDED: skip if auto-hide menubar is hidden — writing contentSize
        // against an off-screen button causes the side-jump on open (#2237).
        let fitting = hostingController.view.fittingSize
        mbkLog("PopoverController", "openPopover -- fittingSize=\(fitting)")
        if fitting.width > 0, fitting.height > 0 {
            if isMenuBarHidden {
                mbkLog("PopoverController",
                       "openPopover -- menubar hidden, SKIP pre-show contentSize write fitting=(\(fitting.width),\(fitting.height))")
            } else {
                let clamped = clamp(fitting)
                mbkLog("PopoverController",
                       "openPopover -- pre-show contentSize write: fitting=\(fitting) clamped=\(clamped) currentContentSize=\(popover.contentSize)")
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0
                    ctx.allowsImplicitAnimation = false
                    popover.contentSize = clamped
                }
                mbkLog("PopoverController",
                       "openPopover -- pre-show contentSize written, popover.contentSize now=\(popover.contentSize)")
            }
        } else {
            mbkLog("PopoverController", "openPopover -- skipping pre-show write: fitting degenerate \(fitting)")
        }

        guard let rect = positioningRect(for: button) else {
            mbkLog("PopoverController", "openPopover -- ABORT: positioningRect returned nil")
            return
        }
        mbkLog("PopoverController", "openPopover -- positioningRect=\(rect) calling popover.show")
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController",
               "openPopover -- popover.show returned isShown=\(popover.isShown) popover.contentSize=\(popover.contentSize)")
        startEventMonitor()

        Task { @MainActor in
            mbkLog("PopoverController", "openPopover -- onDidShow Task hop BEGIN")
            self.onDidShow?()
            mbkLog("PopoverController", "openPopover -- onDidShow Task hop END")
        }
    }

    // panelWindow is a computed var that scans NSApp.windows each time it is
    // called. Call sites that need it more than once in the same logical branch
    // should capture it as a local (e.g. `let pw = panelWindow`) to avoid
    // redundant O(n) scans of the window list. See startEventMonitor for the
    // canonical example.
    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    // Pure predicate — returns true if the popover's panel window has any
    // child windows attached (indicating an active AppKit sheet).
    // Only read this from one call site; capture to a local if you need it
    // more than once in the same branch so any surrounding log fires exactly once.
    private var hasSheetChildWindow: Bool {
        let pw = panelWindow
        let pwChildren = pw?.childWindows ?? []
        mbkLog("PopoverController",
               "hasSheetChildWindow -- panelWindow=\(pw?.windowNumber as Any) childCount=\(pwChildren.count)")
        return !pwChildren.isEmpty
    }

    private func fireOnWillClose(wasForced: Bool) {
        mbkLog("PopoverController", "fireOnWillClose -- wasForced=\(wasForced) onWillCloseFired=\(onWillCloseFired)")
        guard !onWillCloseFired else {
            mbkLog("PopoverController", "fireOnWillClose -- already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PopoverController", "fireOnWillClose -- calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "fireOnWillClose -- onWillClose returned")
    }

    private func forceClose() {
        mbkLog("PopoverController", "forceClose -- BEGIN")
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate hasActiveOverlay was=\(overlayGate.hasActiveOverlay)")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            let children = pw.childWindows ?? []
            mbkLog("PopoverController", "forceClose -- panelWindow #\(pw.windowNumber) childCount=\(children.count)")
            for child in children {
                mbkLog("PopoverController", "forceClose -- removing+closing child #\(child.windowNumber)")
                pw.removeChildWindow(child)
                child.close()
                mbkLog("PopoverController", "forceClose -- child #\(child.windowNumber) closed")
            }
        } else {
            mbkLog("PopoverController", "forceClose -- no panelWindow found")
        }
        mbkLog("PopoverController", "forceClose -- calling performClose")
        popover.performClose(nil)
        mbkLog("PopoverController", "forceClose -- performClose returned")
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        mbkLog("PopoverController", "positioningRect -- button.bounds=\(bounds)")
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds), returning nil")
            return nil
        }
        let rect = NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
        mbkLog("PopoverController", "positioningRect -- rect=\(rect)")
        return rect
    }

    private func setButtonHighlight(_ on: Bool) {
        mbkLog("PopoverController", "setButtonHighlight -- \(on)")
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        mbkLog("PopoverController", "setupPopover -- BEGIN minWidth=\(minWidth) maxWidth=\(maxWidth) maxHeight=\(maxHeight)")
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        mbkLog("PopoverController",
               "setupPopover -- complete popover.contentSize=\(popover.contentSize) animates=\(popover.animates)")
    }

    /// Wraps `view` in the GeometryReader size observer used by `setupPopover`
    /// and `setRootView`. Extracted so both call sites apply identical wrapping.
    private func wrapped(_ view: AnyView) -> AnyView {
        mbkLog("PopoverController", "wrapped -- installing GeometryReader size observer")
        return AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] oldSize, newSize in
                            mbkLog("PopoverController",
                                   "GR.onChange -- oldSize=\(oldSize) newSize=\(newSize)")
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            mbkLog("PopoverController",
                                   "GR.onAppear -- size=\(geo.size)")
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        )
    }

    private func clamp(_ size: CGSize) -> CGSize {
        let clamped = CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
        mbkLog("PopoverController",
               "clamp -- in=(\(size.width),\(size.height)) out=(\(clamped.width),\(clamped.height)) minWidth=\(minWidth) maxWidth=\(maxWidth) maxHeight=\(maxHeight)")
        return clamped
    }

    // swiftlint:disable:next function_body_length
    private func applyContentSize(_ preferred: CGSize) {
        mbkLog("PopoverController",
               "applyContentSize -- ENTER preferred=(\(preferred.width),\(preferred.height))")

        let clamped = clamp(preferred)
        mbkLog("PopoverController",
               "applyContentSize -- clamped=(\(clamped.width),\(clamped.height)) currentContentSize=\(popover.contentSize)")

        guard clamped.width > 0, clamped.height > 0 else {
            mbkLog("PopoverController", "applyContentSize -- SKIP: clamped degenerate (\(clamped.width),\(clamped.height))")
            return
        }

        let widthDelta = abs(popover.contentSize.width - clamped.width)
        let heightDelta = abs(popover.contentSize.height - clamped.height)
        mbkLog("PopoverController",
               "applyContentSize -- widthDelta=\(widthDelta) heightDelta=\(heightDelta) threshold=1")

        guard widthDelta > 1 || heightDelta > 1 else {
            mbkLog("PopoverController",
                   "applyContentSize -- SKIP: change below threshold widthDelta=\(widthDelta) heightDelta=\(heightDelta)")
            return
        }

        // GUARD: skip ALL contentSize writes when the auto-hide menubar is hidden.
        if isMenuBarHidden {
            mbkLog("PopoverController",
                   "applyContentSize -- SKIP: menubar hidden, would write (\(clamped.width),\(clamped.height))")
            return
        }

        // Capture whether width is actually changing BEFORE the contentSize write.
        // Used below to decide whether to recompute newOrigin.x or leave X unchanged.
        //
        // WHY capture before the write:
        // We compare against popover.contentSize.width (the old value). After
        // popover.contentSize = clamped the old value is gone.
        let widthChanged = widthDelta > 1
        let heightChanged = heightDelta > 1
        let oldContentSize = popover.contentSize
        mbkLog("PopoverController",
               "applyContentSize -- widthChanged=\(widthChanged) heightChanged=\(heightChanged) oldContentSize=\(oldContentSize)")

        guard popover.isShown,
              let window = hostingController.view.window,
              let storedAnchor = anchorPoint else {
            mbkLog("PopoverController",
                   "applyContentSize -- not shown path: isShown=\(popover.isShown) hasWindow=\(hostingController.view.window != nil) hasAnchor=\(anchorPoint != nil)")
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                mbkLog("PopoverController",
                       "applyContentSize -- not-shown WRITE (\(clamped.width),\(clamped.height))")
                popover.contentSize = clamped
                mbkLog("PopoverController",
                       "applyContentSize -- not-shown WRITE done, popover.contentSize=\(popover.contentSize)")
            }
            return
        }

        // === SHOWN PATH ===
        // Snapshot every frame value we'll use BEFORE the contentSize write.
        let winFrameBefore = window.frame
        let liveAnchorY = window.frame.maxY
        let buttonWinFrame = statusItem.button?.window?.frame ?? .zero
        let buttonFrame = statusItem.button?.frame ?? .zero
        let buttonMidXScreen = buttonWinFrame.origin.x + buttonFrame.midX

        mbkLog("PopoverController", "applyContentSize -- SHOWN PATH BEGIN")
        mbkLog("PopoverController", "applyContentSize -- winFrameBefore=\(winFrameBefore)")
        mbkLog("PopoverController", "applyContentSize -- liveAnchorY=\(liveAnchorY) (window.frame.maxY)")
        mbkLog("PopoverController", "applyContentSize -- storedAnchor=\(storedAnchor)")
        mbkLog("PopoverController",
               "applyContentSize -- buttonWinFrame=\(buttonWinFrame) buttonFrame=\(buttonFrame) buttonMidXScreen(live)=\(buttonMidXScreen)")
        mbkLog("PopoverController",
               "applyContentSize -- storedAnchor.x=\(storedAnchor.x) vs buttonMidXScreen(live)=\(buttonMidXScreen) diff=\(storedAnchor.x - buttonMidXScreen)")
        mbkLog("PopoverController",
               "applyContentSize -- clamped.width=\(clamped.width) will be used for X centering (NOT window.frame.width post-write)")

        // Popover is shown — write contentSize and immediately re-center the window.
        //
        // WHY liveAnchorY = window.frame.maxY (#2265-3):
        // storedAnchor.y is captured once in popoverWillShow. It drifts from the
        // live window.frame.maxY whenever height changes (row expand, nav change).
        // NSPopover keeps .minY edge attached to the status button, so
        // window.frame.maxY is always the authoritative anchor Y. Use it live.
        //
        // WHY use clamped.width for X centering, NOT window.frame.width (#2268):
        // window.frame.width after popover.contentSize = clamped may not reflect
        // the new width synchronously — AppKit may defer the frame update even
        // inside NSAnimationContext(duration:0). clamped.width IS the width we
        // just wrote, so it is guaranteed correct. Using window.frame.width
        // risks computing the origin from the old or intermediate width, producing
        // the visible horizontal drift / arrow side-jump on width changes.
        //
        // WHY skip newOrigin.x recomputation when width didn't change (#2268):
        // On a pure height resize (widthChanged == false), touching X at all
        // risks sub-pixel rounding drift. Leave the window exactly where it is.
        //
        // ❌ NEVER use window.frame.width / 2 for X centering when widthChanged — use clamped.width / 2.
        // ❌ NEVER revert to storedAnchor.y — arrow-jump regression.
        // ❌ NEVER remove the NSAnimationContext block — header-jump regression.
        // ❌ NEVER use allowsImplicitAnimation: true.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false

            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext BEGIN: writing contentSize=(\(clamped.width),\(clamped.height))")
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext: contentSize written, popover.contentSize=\(popover.contentSize)")

            // Read window frame AFTER contentSize write for diagnostic comparison.
            let winFrameAfterWrite = window.frame
            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext: winFrameAfterWrite=\(winFrameAfterWrite)")
            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext: window.frame.width AFTER write=\(winFrameAfterWrite.width) vs clamped.width=\(clamped.width) diff=\(winFrameAfterWrite.width - clamped.width)")
            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext: window.frame.origin.x AFTER write=\(winFrameAfterWrite.origin.x) vs winFrameBefore.origin.x=\(winFrameBefore.origin.x) diff=\(winFrameAfterWrite.origin.x - winFrameBefore.origin.x)")

            let newOriginX: CGFloat
            if widthChanged {
                // Width changed — recentre using the stored button anchor and clamped.width.
                // clamped.width is the authoritative new width — do NOT use window.frame.width
                // which may not yet reflect the write above (#2268).
                newOriginX = storedAnchor.x - clamped.width / 2
                mbkLog("PopoverController",
                       "applyContentSize -- widthChanged=true: newOriginX = storedAnchor.x(\(storedAnchor.x)) - clamped.width/2(\(clamped.width / 2)) = \(newOriginX)")
            } else {
                // Height-only change — keep current X, do not touch horizontal position.
                newOriginX = winFrameBefore.origin.x
                mbkLog("PopoverController",
                       "applyContentSize -- widthChanged=false (height-only): keeping X=\(newOriginX) (winFrameBefore.origin.x)")
            }

            let newOriginY = liveAnchorY - window.frame.height
            mbkLog("PopoverController",
                   "applyContentSize -- newOriginY = liveAnchorY(\(liveAnchorY)) - window.frame.height(\(window.frame.height)) = \(newOriginY)")

            let newOrigin = NSPoint(x: newOriginX, y: newOriginY)
            mbkLog("PopoverController",
                   "applyContentSize -- calling setFrameOrigin(\(newOrigin)) prev origin=\(winFrameBefore.origin)")
            window.setFrameOrigin(newOrigin)

            let winFrameAfterSet = window.frame
            mbkLog("PopoverController",
                   "applyContentSize -- NSAnimationContext END: winFrameAfterSet=\(winFrameAfterSet)")
            mbkLog("PopoverController",
                   "applyContentSize -- SUMMARY: old=\(winFrameBefore) → new=\(winFrameAfterSet) | storedAnchorX=\(storedAnchor.x) buttonMidXLive=\(buttonMidXScreen) | widthChanged=\(widthChanged) heightChanged=\(heightChanged) | clampedW=\(clamped.width) clampedH=\(clamped.height)")
        }
    }

    private func setupWorkspaceObserver() {
        mbkLog("PopoverController", "setupWorkspaceObserver -- registering")
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            mbkLog("PopoverController",
                   "workspaceObserver -- didActivateApplication: \(activated?.bundleIdentifier ?? "nil")")
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else {
                    mbkLog("PopoverController", "workspaceObserver -- popover not shown, ignoring")
                    return
                }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspaceObserver -- self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController",
                           "workspaceObserver -- overlay active (hasActiveOverlay=true), keeping popover open")
                    return
                }
                mbkLog("PopoverController",
                       "workspaceObserver -- other app activated, calling performClose")
                self.popover.performClose(nil)
            }
        }
        mbkLog("PopoverController", "setupWorkspaceObserver -- registered")
    }

    private func startEventMonitor() {
        guard eventMonitor == nil else {
            mbkLog("PopoverController", "startEventMonitor -- already running, skip")
            return
        }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            mbkLog("PopoverController",
                   "eventMonitor -- fired type=\(event.type.rawValue) location=\(event.locationInWindow)")
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController",
                       "eventMonitor -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PopoverController", "eventMonitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = self.hasSheetChildWindow
                        mbkLog("PopoverController", "eventMonitor -- hasSheet=\(hasSheet)")
                        if hasSheet {
                            mbkLog("PopoverController", "eventMonitor -- sheet overlay, calling forceClose")
                            self.forceClose()
                        } else {
                            mbkLog("PopoverController", "eventMonitor -- picker/alert overlay, ignoring outside click")
                        }
                    }
                } else {
                    mbkLog("PopoverController", "eventMonitor -- no overlay, calling performClose")
                    self.popover.performClose(nil)
                }
            }
        }
        mbkLog("PopoverController", "startEventMonitor -- monitor installed")
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else {
            mbkLog("PopoverController", "stopEventMonitor -- no monitor running, skip")
            return
        }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "stopEventMonitor -- monitor removed")
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
        mbkLog("PopoverController", "popoverWillShow -- BEGIN")
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow, anchor skipped")
            return
        }

        // Derive anchorPoint.x from the status button's own screen coordinate.
        //
        // WHY NOT window.frame.midX:
        // At the moment popoverWillShow fires, AppKit has just placed the popover
        // window via show(relativeTo:of:preferredEdge:) but may not have finished
        // settling the frame. window.frame.midX can therefore be slightly off from
        // the true center of the status button. Any error here propagates to every
        // setFrameOrigin call in applyContentSize.
        //
        // WHY buttonWindow.frame.origin.x + button.frame.midX:
        // button.frame is in the button window's coordinate space. Adding the
        // button window's screen origin gives the button's true screen midX —
        // the point the NSPopover arrow is anchored to. This value is stable
        // regardless of when popoverWillShow fires relative to window placement.
        //
        // FALLBACK: if button.window is nil for any reason, fall back to
        // window.frame.midX (previous behaviour) so the popover still appears.
        let buttonAnchorX: CGFloat
        if let button = statusItem.button, let buttonWindow = button.window {
            let buttonWinOriginX = buttonWindow.frame.origin.x
            let buttonLocalMidX = button.frame.midX
            buttonAnchorX = buttonWinOriginX + buttonLocalMidX
            mbkLog("PopoverController",
                   "popoverWillShow -- anchorX from button: buttonWin.frame=\(buttonWindow.frame) button.frame=\(button.frame) buttonWinOriginX=\(buttonWinOriginX) buttonLocalMidX=\(buttonLocalMidX) anchorX=\(buttonAnchorX)")
        } else {
            buttonAnchorX = window.frame.midX
            mbkLog("PopoverController",
                   "popoverWillShow -- WARNING: button.window nil, fallback anchorX=window.frame.midX=\(buttonAnchorX)")
        }

        let winFrame = window.frame
        anchorPoint = NSPoint(x: buttonAnchorX, y: winFrame.maxY)
        mbkLog("PopoverController",
               "popoverWillShow -- anchor=\(anchorPoint!) win.frame=\(winFrame) win.frame.midX=\(winFrame.midX) win#\(window.windowNumber)")
        mbkLog("PopoverController",
               "popoverWillShow -- anchorX=\(buttonAnchorX) vs window.frame.midX=\(winFrame.midX) diff=\(buttonAnchorX - winFrame.midX)")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController",
               "popoverShouldClose -- hasActiveOverlay=\(block) → returning \(!block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose -- BEGIN")
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        anchorPoint = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- anchor cleared, gate reset, onWillCloseFired reset")
    }
}
