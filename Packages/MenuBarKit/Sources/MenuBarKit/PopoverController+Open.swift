// PopoverController+Open.swift
// MenuBarKit
//
// Open/close logic for MBKPopoverController.
// See PopoverController.swift file header for full design notes.

import AppKit
import SwiftUI

/// Open/close logic, positioning, highlight, and popover/view setup for `MBKPopoverController`.
extension MBKPopoverController {

    // MARK: - Auto-hide menubar guard

    /// Returns `true` when the macOS auto-hide menubar is currently hidden (slid off-screen).
    ///
    /// `screenH < 0` signals a nil screen — treated as hidden.
    /// `buttonY > screenH` means the button window has slid above the screen top.
    /// Uses `>` (not `>=`): `buttonY == screenH` is the normal flush resting position.
    var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let buttonScreen = button.window?.screen
        let screenH = buttonScreen.map { $0.frame.height } ?? -1
        let buttonY = button.window?.frame.maxY ?? -1
        let hidden = screenH < 0 || buttonY > screenH
        mbkLog("PopoverController", "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
    }

    /// Button center X in screen coordinates.
    /// Derived as `buttonWin.frame.minX + button.frame.midX` so it is correct
    /// in both visible and hidden mode (`statusBarWindow.frame.midX` can be
    /// stale when the menubar is hidden).
    var buttonScreenMidX: CGFloat? {
        guard let button = statusItem.button,
              let win = button.window else { return nil }
        return win.frame.minX + button.frame.midX
    }

    // MARK: - Toggle / open

    /// Toggles the popover open or closed when the status-bar button is clicked.
    @objc func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Shows the popover anchored to the status-bar button.
    /// Handles `onWillShow`/`onDidShow` callbacks and post-show X correction
    /// for the hidden-menubar case.
    func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if !menuBarHidden, let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")

        // Post-show reposition when menubar is hidden.
        // AppKit anchors the window using the button's stale off-screen position — bad X.
        // Override immediately with lastKnownAnchorX before the user sees it.
        if menuBarHidden,
           let liveAnchorX = lastKnownAnchorX,
           let window = hostingController.view.window {
            let correctedOrigin = NSPoint(
                x: liveAnchorX - window.frame.width / 2,
                y: window.frame.origin.y
            )
            window.setFrameOrigin(correctedOrigin)
            mbkLog("PopoverController",
                   "openPopover -- menubar hidden, post-show REPOSITION liveAnchorX=\(liveAnchorX) w=\(window.frame.width) origin=\(correctedOrigin)")
        } else if menuBarHidden {
            mbkLog("PopoverController", "openPopover -- menubar hidden but no lastKnownAnchorX yet, cannot reposition")
        }

        startEventMonitor()

        // Explicitly correct arrow anchor after show() so the first open is
        // always correct even if the KVO fires before the window is assigned.
        correctArrowAnchorPoint()

        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            guard self.popover.isShown else {
                mbkLog("PopoverController", "onDidShow Task hop -- popover already closed, skipping onDidShow")
                return
            }
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    // MARK: - Arrow anchor correction

    /// Corrects the popover arrow position by writing directly to `NSPopoverFrame.anchorPoint`
    /// (private API, KVC-accessible since macOS 10.8).
    ///
    /// Called from the `contentSizeObserver` KVO block on every `popover.contentSize` change
    /// and explicitly at the end of `openPopover()` as a first-open safety net.
    ///
    /// `anchorPoint` is a normalised `CGPoint` within the popover frame where
    /// x=0.5 centres the arrow. We derive it from `buttonScreenMidX` relative to
    /// the current window frame. Clamped to [0.05, 0.95] to keep the arrow visible.
    ///
    /// The `responds(to:)` guard makes this a silent no-op if Apple ever removes or
    /// renames `NSPopoverFrame` — no crash, no App Store risk.
    func correctArrowAnchorPoint() {
        guard let window = hostingController.view.window,
              let frameView = window.contentView?.superview,
              frameView.responds(to: NSSelectorFromString("anchorPoint")),
              let anchorX = buttonScreenMidX,
              window.frame.width > 0 else { return }
        let normalizedX = (anchorX - window.frame.minX) / window.frame.width
        let clamped = max(0.05, min(0.95, normalizedX))
        frameView.setValue(
            NSValue(point: CGPoint(x: clamped, y: 0)),
            forKey: "anchorPoint"
        )
        mbkLog("PopoverController",
               "correctArrowAnchorPoint -- anchorX=\(anchorX) winMinX=\(window.frame.minX) winW=\(window.frame.width) normalizedX=\(normalizedX) clamped=\(clamped)")
    }

    // MARK: - Panel / sheet helpers

    /// The `NSWindow` with `.nonactivatingPanel` style mask, if any.
    var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    /// `true` when the panel window has at least one child window (i.e. a sheet is attached).
    var hasSheetChildWindow: Bool {
        !(panelWindow?.childWindows ?? []).isEmpty
    }

    // MARK: - Close helpers

    /// Fires `onWillClose` exactly once per session, guarded by `onWillCloseFired`.
    func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else {
            mbkLog("PopoverController", "onWillClose already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    /// Closes all child windows of the panel and calls `popover.performClose`.
    /// Used when an outside click arrives while a non-file-picker sheet is active.
    func forceClose() {
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

    // MARK: - Positioning / highlight

    /// Returns a 1pt-wide rect centered on `button.bounds.midX`, used as the
    /// `positioningRect` for `NSPopover.show`.
    /// Returns `nil` if `button.bounds` are degenerate (zero width or height).
    func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    /// Sets the status-bar button's highlighted state.
    func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover / view setup

    /// Creates and configures the `NSPopover` with the hosted SwiftUI root view.
    ///
    /// `sizingOptions = [.preferredContentSize]` lets AppKit drive `contentSize`
    /// directly from SwiftUI's natural layout — no manual GeometryReader chain needed.
    /// Arrow position is corrected by `correctArrowAnchorPoint()` via the
    /// `contentSizeObserver` KVO block on every size change.
    func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self

        // KVO: correct arrow anchor on every AppKit-driven contentSize write.
        // DispatchQueue.main.async ensures the window frame has been committed
        // before we read it to derive the normalised anchor X.
        contentSizeObserver = popover.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.correctArrowAnchorPoint() }
        }
    }
}
