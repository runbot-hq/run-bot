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
    /// Handles `onWillShow`/`onDidShow` callbacks.
    ///
    /// Always passes the real button rect to `show()` — in both visible and hidden
    /// menubar mode. AppKit uses the real rect to compute `anchorPoint` for arrow
    /// rendering; a synthetic rect (localMidX-based) produces an off-center arrow
    /// that cannot be corrected post-show.
    ///
    /// In hidden-menubar mode the window AppKit places will have the wrong X because
    /// the button window frame is stale. `handlePopoverWindowMoved` fires immediately
    /// after show() and corrects the X to `lastKnownAnchorX - width/2`, which centers
    /// the window (and therefore the arrow) correctly. This is the same pattern used
    /// in PR #2289.
    ///
    /// `lastKnownAnchorX` is always snapshotted on open because button window X
    /// (minX) is stable in both visible and hidden mode — only Y goes stale.
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

        // Always use the real button rect for positioningRect — in both visible and
        // hidden menubar mode. AppKit feeds this rect to _computeAnchorPointForFrame:
        // to derive the arrow's normalized X. A synthetic rect with a near-zero localMidX
        // produces an off-center anchorPoint that no post-show private-API write can fix.
        //
        // In hidden mode the resulting window X will be wrong (stale button frame), but
        // handlePopoverWindowMoved corrects it immediately via setFrameOrigin using
        // lastKnownAnchorX. AppKit then recomputes anchorPoint from the centered window
        // and the real rect, landing the arrow at ~0.5 (centered).
        guard let posRect = positioningRect(for: button) else { return }
        if menuBarHidden {
            mbkLog("PopoverController", "openPopover -- hidden-menubar using real posRect=\(posRect)")
        } else {
            mbkLog("PopoverController", "openPopover -- visible-menubar posRect=\(posRect)")
        }

        popover.show(relativeTo: posRect, of: button, preferredEdge: .minY)
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
    /// Called from `popoverDidShow` (via async hop) AND from `handlePopoverWindowMoved`
    /// so that every `setFrameOrigin` call — which triggers AppKit’s own
    /// `_updateAnchorPointForFrame:` and stomps our value — is immediately
    /// followed by a re-stamp of the correct normalized X.
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
    /// Calls `correctArrowAnchorPoint()` after every `setFrameOrigin` because
    /// AppKit’s `_updateAnchorPointForFrame:` fires on each move/resize and
    /// overwrites our anchorPoint with a value derived from the stale
    /// positioningRect — re-stamping immediately after keeps the arrow centered.
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

    /// Removes the `didMove` and `didResize` observers and clears pinned origin.
    /// Called from `popoverDidClose`.
    func unpinPopoverWindow() {
        let nc = NotificationCenter.default
        if let obs = windowMoveObserver { nc.removeObserver(obs) }
        if let obs = windowResizeObserver { nc.removeObserver(obs) }
        windowMoveObserver = nil
        windowResizeObserver = nil
        pinnedWindowMinX = nil
        pinnedWindowMaxY = nil
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
