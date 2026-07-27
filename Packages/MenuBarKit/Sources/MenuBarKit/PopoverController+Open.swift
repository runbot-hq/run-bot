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
    /// `buttonY >= screenH` covers the flush-at-top-edge case: when auto-hide is on
    /// and the bar has slid away, the button window sits exactly at screenH (buttonY == screenH).
    /// Uses `>=` (not `>`): `buttonY == screenH` is the hidden resting position.
    var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let buttonWin = button.window
        let buttonScreen = buttonWin?.screen
        let screenFrame = buttonScreen?.frame ?? .zero
        let visibleFrame = buttonScreen?.visibleFrame ?? .zero
        let winFrame = buttonWin?.frame ?? .zero
        let screenH = screenFrame.height > 0 ? screenFrame.height : -1
        let buttonY = winFrame.maxY
        let hidden = screenH < 0 || buttonY >= screenH
        mbkLog("PopoverController",
               "isMenuBarHidden=\(hidden) buttonWinFrame=\(winFrame) screenFrame=\(screenFrame) visibleFrame=\(visibleFrame) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
    }

    /// Button center X in screen coordinates.
    /// Derived as `buttonWin.frame.minX + button.frame.midX` so it is correct
    /// in both visible and hidden mode (`statusBarWindow.frame.midX` can be
    /// stale when the menubar is hidden).
    var buttonScreenMidX: CGFloat? {
        guard let button = statusItem.button,
              let win = button.window else { return nil }
        let midX = win.frame.minX + button.frame.midX
        mbkLog("PopoverController", "buttonScreenMidX=\(midX) winMinX=\(win.frame.minX) buttonMidX=\(button.frame.midX)")
        return midX
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
    ///
    /// In **visible-menubar mode**: passes the real button rect as `positioningRect`
    /// directly to `button` — standard path, no subview needed.
    ///
    /// In **hidden-menubar mode**: AppKit's button window frame is stale (Y off-screen),
    /// so we cannot rely on AppKit to compute the arrow position correctly.
    /// Instead we create a 1×22pt invisible `arrowPositioningView` as a subview of
    /// `button`, centered at `button.bounds.midX`, and pass it as the `positioningView`.
    /// After `handlePopoverWindowMoved` corrects the window X via `setFrameOrigin`,
    /// `correctArrowAnchorPoint` repositions `arrowPositioningView` so its screen-X
    /// equals `lastKnownAnchorX` — AppKit redraws the arrow to follow the subview.
    /// This is pure public API; no private selectors required.
    func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        if menuBarHidden {
            // Create (or reuse) the invisible positioning subview centered on the button.
            let pv: NSView
            if let existing = arrowPositioningView, existing.superview == button {
                pv = existing
            } else {
                arrowPositioningView?.removeFromSuperview()
                let v = NSView(frame: NSRect(x: button.bounds.midX - 0.5, y: button.bounds.minY, width: 1, height: button.bounds.height))
                button.addSubview(v)
                arrowPositioningView = v
                pv = v
            }
            mbkLog("PopoverController", "openPopover -- hidden-menubar positioningView frame=\(pv.frame)")
            popover.show(relativeTo: pv.bounds, of: pv, preferredEdge: .minY)
        } else {
            guard let posRect = positioningRect(for: button) else { return }
            mbkLog("PopoverController", "openPopover -- visible-menubar posRect=\(posRect)")
            popover.show(relativeTo: posRect, of: button, preferredEdge: .minY)
        }

        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown -- window frame=\(hostingController.view.window?.frame ?? .zero)")

        startEventMonitor()

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

    /// Corrects the popover arrow in hidden-menubar mode by repositioning
    /// `arrowPositioningView` so its screen-X equals `lastKnownAnchorX`.
    ///
    /// AppKit derives the arrow X from the `positioningView`'s position in the
    /// button window's coordinate space — that is the public-API source of truth.
    /// Neither `anchorPoint` KVC nor `_setArrowX:` work on macOS 26.
    ///
    /// The conversion: `buttonLocalX = lastKnownAnchorX - buttonWin.frame.minX`
    /// then we set `arrowPositioningView.frame.origin.x = buttonLocalX - 0.5`
    /// (keeping the view 1pt wide, centered on the target screen X).
    ///
    /// No-op in visible-menubar mode (no `arrowPositioningView` created).
    func correctArrowAnchorPoint() {
        guard let pv = arrowPositioningView,
              let button = statusItem.button,
              let buttonWin = button.window,
              let anchorX = lastKnownAnchorX else { return }
        let localX = anchorX - buttonWin.frame.minX
        let newFrame = NSRect(x: localX - 0.5, y: pv.frame.minY, width: 1, height: pv.frame.height)
        pv.frame = newFrame
        mbkLog("PopoverController",
               "correctArrowAnchorPoint -- anchorX=\(anchorX) buttonWinMinX=\(buttonWin.frame.minX) localX=\(localX) pvFrame=\(newFrame)")
    }

    // MARK: - Window position pin

    /// Snapshots the popover window's top edge and subscribes to `didMove` and
    /// `didResize` notifications so that if AppKit repositions or resizes the window
    /// (e.g. during a scroll-view height change in hidden-menubar mode) we immediately
    /// recompute `origin.y = pinnedWindowMaxY - height` to keep the top edge fixed
    /// just below the menu bar.
    ///
    /// `pinnedWindowMaxY` is clamped to `screen.visibleFrame.maxY` so the popover
    /// never intrudes into the hidden menubar zone (4 pt gap between window.maxY
    /// and visibleFrame.maxY that AppKit introduces when the bar is hidden).
    ///
    /// Must be called after the popover frame has settled (i.e. from the same
    /// async hop as `correctArrowAnchorPoint` in `popoverDidShow`).
    func pinPopoverWindow() {
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "pinPopoverWindow -- no window, skipping")
            return
        }
        let pinnedX = window.frame.minX
        // Use visibleFrame.maxY as the ceiling so the top edge stays flush with
        // the visible area regardless of the 4 pt overshoot AppKit introduces.
        let pinnedMaxY = window.screen?.visibleFrame.maxY
            ?? (window.frame.origin.y + window.frame.height)
        pinnedWindowMinX = pinnedX
        pinnedWindowMaxY = pinnedMaxY
        mbkLog("PopoverController", "pinPopoverWindow -- pinnedX=\(pinnedX) pinnedMaxY=\(pinnedMaxY) winFrame=\(window.frame)")

        let nc = NotificationCenter.default
        windowMoveObserver = nc.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            self?.handlePopoverWindowMoved(window: window)
        }
        windowResizeObserver = nc.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            self?.handlePopoverWindowMoved(window: window)
        }
    }

    /// Called when the popover window moves or resizes.
    /// Recomputes the correct X as `lastKnownAnchorX - window.frame.width / 2`
    /// so the window stays centred on the button regardless of width changes.
    /// Recomputes the correct Y as `pinnedWindowMaxY - window.frame.height`
    /// so the top edge stays fixed regardless of height changes.
    /// Calls `correctArrowAnchorPoint()` after every `setFrameOrigin` to reposition
    /// `arrowPositioningView` so AppKit redraws the arrow at the correct X.
    private func handlePopoverWindowMoved(window: NSWindow?) {
        guard popover.isShown,
              let window,
              let anchorX = lastKnownAnchorX else { return }
        let correctX = anchorX - window.frame.width / 2
        let correctY = (pinnedWindowMaxY ?? (window.frame.origin.y + window.frame.height)) - window.frame.height
        guard window.frame.minX != correctX || window.frame.origin.y != correctY else { return }
        let driftedX = window.frame.minX
        let driftedY = window.frame.origin.y
        window.setFrameOrigin(NSPoint(x: correctX, y: correctY))
        mbkLog("PopoverController",
               "handlePopoverWindowMoved -- driftedX=\(driftedX) driftedY=\(driftedY) restoredX=\(correctX) restoredY=\(correctY) newFrame=\(window.frame)")
        correctArrowAnchorPoint()
    }

    /// Removes the `didMove` and `didResize` observers, clears pinned origin,
    /// and removes `arrowPositioningView` from the button.
    /// Called from `popoverDidClose`.
    func unpinPopoverWindow() {
        let nc = NotificationCenter.default
        if let obs = windowMoveObserver { nc.removeObserver(obs) }
        if let obs = windowResizeObserver { nc.removeObserver(obs) }
        windowMoveObserver = nil
        windowResizeObserver = nil
        pinnedWindowMinX = nil
        pinnedWindowMaxY = nil
        arrowPositioningView?.removeFromSuperview()
        arrowPositioningView = nil
        mbkLog("PopoverController", "unpinPopoverWindow -- observers removed, arrowPositioningView removed")
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
    /// `positioningRect` for `NSPopover.show` in visible-menubar mode.
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
    /// Arrow position in hidden-menubar mode is controlled by repositioning
    /// `arrowPositioningView` (a subview of the button) — pure public API.
    func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }
}
