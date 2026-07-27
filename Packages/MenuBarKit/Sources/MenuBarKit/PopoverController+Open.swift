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
    /// Arrow positioning strategy: a throwaway 1×1-pt `NSView` (the “positioning
    /// view”) is added as a subview of the status-bar button at the correct
    /// button-local X coordinate, and `show(relativeTo:of:preferredEdge:)` is
    /// called with that view. AppKit derives the arrow position from the
    /// positioning view’s screen-coordinate midX at call time and bakes it into
    /// the window — no post-show KVC writes needed. The positioning view is
    /// removed immediately after `show()` returns.
    ///
    /// Hidden-menubar path: `lastKnownAnchorX` (snapshotted from the button
    /// window’s stable minX + button midX) is converted to button-local coords
    /// and used as the positioning view’s X so the arrow lands correctly even
    /// when the button window has slid off-screen.
    ///
    /// Visible-menubar path: the positioning view is placed at `button.bounds.midX`
    /// — identical to the old `positioningRect` approach.
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

        // Compute the button-local X at which to place the positioning view.
        //
        // Hidden-menubar path: convert lastKnownAnchorX (screen coords) to
        // button-local coords by subtracting buttonWin.frame.minX.
        // Visible-menubar path: use button.bounds.midX directly.
        let localMidX: CGFloat
        if menuBarHidden, let knownScreenX = lastKnownAnchorX {
            localMidX = knownScreenX - buttonWin.frame.minX
            mbkLog("PopoverController",
                   "openPopover -- hidden-menubar posView localMidX=\(localMidX) knownScreenX=\(knownScreenX) buttonWinMinX=\(buttonWin.frame.minX) buttonBounds=\(button.bounds)")
        } else {
            localMidX = button.bounds.midX
            if menuBarHidden {
                mbkLog("PopoverController", "openPopover -- hidden-menubar but no lastKnownAnchorX, using bounds.midX=\(localMidX)")
            } else {
                mbkLog("PopoverController", "openPopover -- visible-menubar posView localMidX=\(localMidX) buttonWinMinX=\(buttonWin.frame.minX)")
            }
        }

        // Create a throwaway 1×1-pt positioning view, add it as a subview of the
        // button at localMidX, call show(), then remove it immediately.
        // AppKit reads the positioning view’s screen-coordinate midX at the
        // moment show() is called and bakes the correct arrow position into the
        // popover window — no anchorPoint KVC needed.
        let posView = NSView(frame: NSRect(x: localMidX - 0.5,
                                          y: button.bounds.minY,
                                          width: 1,
                                          height: max(button.bounds.height, 1)))
        button.addSubview(posView)
        popover.show(relativeTo: posView.bounds, of: posView, preferredEdge: .minY)
        posView.removeFromSuperview()
        mbkLog("PopoverController", "openPopover -- posView localMidX=\(localMidX) posView removed; window frame=\(hostingController.view.window?.frame ?? .zero)")

        NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - Window position pin

    /// Snapshots the popover window’s top edge (`maxY = origin.y + height`) and
    /// subscribes to `didMove` and `didResize` notifications so that if AppKit
    /// repositions or resizes the window (e.g. during a scroll-view height change
    /// in hidden-menubar mode) we immediately recompute `origin.y = pinnedWindowMaxY
    /// - height` to keep the top edge fixed just below the menu bar.
    ///
    /// Window X is intentionally not pinned here — AppKit owns horizontal
    /// placement via the positioning view used in `openPopover`.
    ///
    /// Must be called after the popover frame has settled (i.e. from the
    /// `DispatchQueue.main.async` hop in `popoverDidShow`).
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
    /// Recomputes the correct Y as `pinnedWindowMaxY - window.frame.height`
    /// so the top edge stays fixed just below the menu bar regardless of
    /// height changes. Window X is left for AppKit to manage.
    private func handlePopoverWindowMoved(window: NSWindow?) {
        guard popover.isShown,
              let window else { return }
        let correctY = (pinnedWindowMaxY ?? (window.frame.origin.y + window.frame.height)) - window.frame.height
        guard window.frame.origin.y != correctY else { return }
        let driftedY = window.frame.origin.y
        window.setFrameOrigin(NSPoint(x: window.frame.minX, y: correctY))
        mbkLog("PopoverController",
               "handlePopoverWindowMoved -- driftedY=\(driftedY) restoredY=\(correctY) newFrame=\(window.frame)")
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
    /// directly from SwiftUI’s natural layout — no manual GeometryReader chain needed.
    /// Arrow position is determined at `show()` time via a throwaway positioning
    /// view added to the button — see `openPopover()`.
    func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
        // contentSizeObserver intentionally absent.
        // Arrow position is owned by the positioning-view approach in openPopover().
        // KVO on contentSize is not needed.
    }
}
