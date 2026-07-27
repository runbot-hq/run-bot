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
    /// Arrow placement strategy:
    ///   AppKit computes the arrow tip from the **screen position of the
    ///   `positioningView` argument** passed to `show(relativeTo:of:preferredEdge:)`.
    ///   Passing `of: button` with a synthetic rect does NOT move the arrow —
    ///   AppKit ignores the rect and uses the button's own stale screen frame
    ///   (which is off-screen when auto-hide is active).
    ///
    ///   The fix: create an ephemeral 1pt-wide `NSView` (`positioningView`),
    ///   add it as a subview of the button at the correct local X, and pass it
    ///   as the `positioningView`. AppKit reads its live screen frame and places
    ///   the arrow correctly even when the button window has slid off-screen.
    ///   The subview is removed in `popoverDidClose`.
    ///
    /// `lastKnownAnchorX` is snapshotted on every open because button window X
    /// (minX) is stable in both visible and hidden mode — only Y goes stale.
    func openPopover() {
        guard let button = statusItem.button,
              let buttonWin = button.window else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        // Determine the button-local X for the positioning subview.
        //
        // Visible mode: use the button's own midX directly.
        // Hidden mode: the button window frame.minX is stale (slid off-screen),
        // but lastKnownAnchorX (snapshotted from the last reliable open) is accurate.
        // Convert back to button-local coords: localMidX = knownScreenX - buttonWin.frame.minX.
        // This gives AppKit the correct screen X for arrow placement even when
        // the status-bar window has slid away.
        let localMidX: CGFloat
        if menuBarHidden, let knownScreenX = lastKnownAnchorX {
            localMidX = knownScreenX - buttonWin.frame.minX
            mbkLog("PopoverController",
                   "openPopover -- hidden-menubar localMidX=\(localMidX) knownScreenX=\(knownScreenX) buttonWinMinX=\(buttonWin.frame.minX)")
        } else {
            localMidX = button.bounds.midX
            mbkLog("PopoverController",
                   "openPopover -- visible-menubar localMidX=\(localMidX) buttonWinMinX=\(buttonWin.frame.minX)")
        }

        // Remove any leftover positioning view from a previous open that
        // closed without firing popoverDidClose (defensive).
        positioningView?.removeFromSuperview()

        // Create the ephemeral positioning subview.
        // AppKit reads this view's screen frame to place the arrow tip.
        // 1pt wide, full button height, centred on localMidX.
        let posView = NSView(frame: NSRect(
            x: localMidX - 0.5,
            y: button.bounds.minY,
            width: 1,
            height: max(button.bounds.height, 1)
        ))
        posView.identifier = NSUserInterfaceItemIdentifier("mbkPositioningView")
        button.addSubview(posView)
        positioningView = posView
        mbkLog("PopoverController",
               "openPopover -- posView frame=\(posView.frame) buttonBounds=\(button.bounds)")

        popover.show(relativeTo: posView.bounds, of: posView, preferredEdge: .minY)
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

    /// Removes the ephemeral positioning subview from the status-bar button.
    /// Called from `popoverDidClose` so the button is clean for the next open.
    func removePositioningView() {
        positioningView?.removeFromSuperview()
        positioningView = nil
        mbkLog("PopoverController", "removePositioningView -- removed")
    }

    // MARK: - Window position pin

    /// Snapshots the popover window's top edge (`maxY = origin.y + height`) and
    /// subscribes to `didMove` and `didResize` notifications so that if AppKit
    /// repositions or resizes the window (e.g. during a scroll-view height change
    /// in hidden-menubar mode) we immediately recompute `origin.y = pinnedWindowMaxY
    /// - height` to keep the top edge fixed just below the menu bar.
    ///
    /// Must be called after the popover frame has settled (i.e. from the same
    /// async hop as `pinPopoverWindow` in `popoverDidShow`).
    func pinPopoverWindow() {
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "pinPopoverWindow -- no window, skipping")
            return
        }
        let pinnedX = window.frame.minX
        let pinnedMaxY = window.frame.origin.y + window.frame.height
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
    ///
    /// The `contentSizeObserver` KVO is retained for future use; arrow correction
    /// is now handled by the positioning subview approach and no longer needs it.
    func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        contentSizeObserver = popover.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                // Reserved for future post-resize corrections.
                _ = self
            }
        }
    }
}
