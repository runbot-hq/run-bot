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
        let buttonWin = button.window
        let buttonScreen = buttonWin?.screen
        let screenFrame = buttonScreen?.frame ?? .zero
        let visibleFrame = buttonScreen?.visibleFrame ?? .zero
        let winFrame = buttonWin?.frame ?? .zero
        let screenH = screenFrame.height > 0 ? screenFrame.height : -1
        let buttonY = winFrame.maxY
        let hidden = screenH < 0 || buttonY > screenH
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
    /// Handles `onWillShow`/`onDidShow` callbacks.
    ///
    /// Hidden-menubar mode: feeds AppKit a synthetic `positioningRect` whose midX
    /// is `lastKnownAnchorX` converted to button-local coordinates so `show()`
    /// places the window at the correct X from frame 1 — no post-show jump.
    /// Falls back to the real button rect when no `lastKnownAnchorX` is available
    /// (first-ever open in hidden mode with no prior visible open).
    ///
    /// Visible-menubar mode: uses the real `positioningRect` as before and
    /// snapshots `lastKnownAnchorX` for future hidden-mode opens.
    func openPopover() {
        guard let button = statusItem.button,
              let buttonWin = button.window else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if !menuBarHidden, let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        // Build the positioning rect.
        //
        // Hidden-menubar path: the button window has slid off-screen so its
        // reported frame.minX is stale. AppKit uses the positioningRect to derive
        // the popover window's initial X. By feeding a synthetic rect whose midX
        // is lastKnownAnchorX (screen coords) converted to button-local coords,
        // AppKit places the window at the correct X on frame 1 with no visible jump.
        //
        // Visible-menubar path: use the real button rect unchanged.
        let posRect: NSRect
        if menuBarHidden, let knownScreenX = lastKnownAnchorX {
            let localMidX = knownScreenX - buttonWin.frame.minX
            posRect = NSRect(
                x: localMidX - 0.5,
                y: button.bounds.minY,
                width: 1,
                height: max(button.bounds.height, 1)
            )
            mbkLog("PopoverController",
                   "openPopover -- hidden-menubar synthetic posRect localMidX=\(localMidX) knownScreenX=\(knownScreenX) buttonWinMinX=\(buttonWin.frame.minX) buttonBounds=\(button.bounds)")
        } else {
            guard let real = positioningRect(for: button) else { return }
            posRect = real
            if menuBarHidden {
                mbkLog("PopoverController", "openPopover -- hidden-menubar but no lastKnownAnchorX, using real posRect=\(posRect)")
            } else {
                mbkLog("PopoverController", "openPopover -- visible-menubar posRect=\(posRect) buttonWinMinX=\(buttonWin.frame.minX)")
            }
        }

        popover.show(relativeTo: posRect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown -- window frame=\(hostingController.view.window?.frame ?? .zero)")

        startEventMonitor()

        // correctArrowAnchorPoint() is NOT called here.
        // popoverDidShow fires after show() returns and owns the correction
        // with correct timing — after AppKit's own _updateAnchorPointForFrame:reshape: pass.

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

    /// Corrects the popover arrow by writing `anchorPoint` to the `NSPopoverFrame`
    /// private view that actually owns arrow rendering.
    ///
    /// Uses an inside-out superview walk starting from `hostingController.view`
    /// so we always land on the correct frame-decoration view regardless of how
    /// many intermediate wrappers AppKit inserts (macOS 15/26 adds at least one
    /// between contentView and NSPopoverFrame).
    ///
    /// `responds(to:)` is the safety net — if Apple ever renames the property
    /// the walk finds nothing and the function is a silent no-op.
    ///
    /// Called from `popoverDidShow` (via async hop) so AppKit's own
    /// `_updateAnchorPointForFrame:reshape:` pass has already completed
    /// before we write.
    func correctArrowAnchorPoint() {
        guard let window = hostingController.view.window,
              window.frame.width > 0,
              let anchorX = buttonScreenMidX else { return }

        let anchorPointSel = NSSelectorFromString("anchorPoint")
        var candidate: NSView? = hostingController.view
        var frameView: NSView?
        while let v = candidate {
            if v.responds(to: anchorPointSel) {
                frameView = v
                break
            }
            candidate = v.superview
        }
        guard let frameView else {
            mbkLog("PopoverController", "correctArrowAnchorPoint -- no anchorPoint-capable view found, skipping")
            return
        }

        let normalizedX = (anchorX - window.frame.minX) / window.frame.width
        let clamped = max(0.05, min(0.95, normalizedX))
        frameView.setValue(
            NSValue(point: CGPoint(x: clamped, y: 0)),
            forKey: "anchorPoint"
        )
        mbkLog("PopoverController",
               "correctArrowAnchorPoint -- anchorX=\(anchorX) winFrame=\(window.frame) normalizedX=\(normalizedX) clamped=\(clamped) target=\(type(of: frameView))")
    }

    // MARK: - Window position pin

    /// Snapshots the popover window's `minX` and subscribes to `didMove` and
    /// `didResize` notifications so that if AppKit repositions the window
    /// horizontally (e.g. during a scroll-view height change in hidden-menubar
    /// mode) we immediately restore the original `minX`.
    ///
    /// Must be called after the popover frame has settled (i.e. from the same
    /// async hop as `correctArrowAnchorPoint` in `popoverDidShow`).
    func pinPopoverWindow() {
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "pinPopoverWindow -- no window, skipping")
            return
        }
        let pinnedX = window.frame.minX
        pinnedWindowMinX = pinnedX
        mbkLog("PopoverController", "pinPopoverWindow -- pinnedX=\(pinnedX) winFrame=\(window.frame)")

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
    /// If the window's `minX` has drifted from `pinnedWindowMinX`, restore it.
    private func handlePopoverWindowMoved(window: NSWindow?) {
        guard popover.isShown,
              let window,
              let pinnedX = pinnedWindowMinX,
              window.frame.minX != pinnedX else { return }
        let drifted = window.frame.minX
        var f = window.frame
        f.origin.x = pinnedX
        window.setFrameOrigin(f.origin)
        mbkLog("PopoverController",
               "handlePopoverWindowMoved -- driftedX=\(drifted) restoredX=\(pinnedX) newFrame=\(window.frame)")
        // Re-correct arrow after restoring position so normalizedX is valid.
        correctArrowAnchorPoint()
    }

    /// Removes the `didMove` and `didResize` observers and clears `pinnedWindowMinX`.
    /// Called from `popoverDidClose`.
    func unpinPopoverWindow() {
        let nc = NotificationCenter.default
        if let obs = windowMoveObserver { nc.removeObserver(obs) }
        if let obs = windowResizeObserver { nc.removeObserver(obs) }
        windowMoveObserver = nil
        windowResizeObserver = nil
        pinnedWindowMinX = nil
        mbkLog("PopoverController", "unpinPopoverWindow -- observers removed")
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
    /// Arrow position is corrected by `correctArrowAnchorPoint()` via `popoverDidShow`
    /// after AppKit's own layout pass completes.
    func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        // contentSizeObserver intentionally absent.
        // Arrow correction is owned by popoverDidShow (after AppKit's own
        // _updateAnchorPointForFrame:reshape: pass completes). KVO on
        // contentSize fires too early and loses the race.
    }
}
