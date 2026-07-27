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
    /// A nil button window (possible during startup before the status item is attached)
    /// is treated as hidden so the caller falls back to the safe hidden-menubar path.
    /// Note: returning `true` here is safe because `openPopover()` gates the hidden
    /// path on `lastKnownAnchorX != nil`; on first-ever open that binding fails and
    /// the visible-menubar else-branch fires instead.
    ///
    /// Asymmetry note: `statusItem.button == nil` returns `false` (button not yet
    /// constructed — no open can be in progress) while `button.window == nil` returns
    /// `true` (button exists but window not yet attached — treat as hidden for safety).
    /// These are distinct lifecycle states, not equivalent nil checks.
    var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        guard let buttonWin = button.window else {
            mbkLog("PopoverController", "isMenuBarHidden -- button.window is nil, treating as hidden")
            return true
        }
        let buttonScreen = buttonWin.screen
        let screenFrame = buttonScreen?.frame ?? .zero
        // visibleFrame is not used in the hidden calculation — included in mbkLog only.
        let visibleFrame = buttonScreen?.visibleFrame ?? .zero
        let winFrame = buttonWin.frame
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
    /// directly to `button` — standard path.
    ///
    /// In **hidden-menubar mode**: AppKit's button window frame is stale (Y off-screen),
    /// so the arrow position cannot be derived from the button's coordinate space.
    /// An invisible 20×1pt `NSPanel` (`arrowAnchorPanel`) is created at
    /// `lastKnownAnchorX - 10` in screen coordinates (Y = `visibleFrame.maxY - 1`)
    /// and passed as the `positioningView`. AppKit reads the panel's screen origin at
    /// show() time, baking the arrow at the correct center X.
    /// The panel is kept alive (alphaValue=0) until `unpinPopoverWindow()` closes it
    /// on `popoverDidClose` — closing it earlier causes AppKit to lose the anchor
    /// and jump the popover to (0, y) on the next resize event.
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

        if menuBarHidden, let anchorX = lastKnownAnchorX, let screen = button.window?.screen ?? NSScreen.main {
            let panelY = screen.visibleFrame.maxY - 1
            let panelRect = NSRect(x: anchorX - 10, y: panelY, width: 20, height: 1)
            let panel = NSPanel(
                contentRect: panelRect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.alphaValue = 0
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.orderFront(nil)
            // Defensively close any stale panel before overwriting the reference.
            // Normally unpinPopoverWindow() closes it in popoverDidClose, but on a
            // rapid re-open race the old panel could still be alive here.
            arrowAnchorPanel?.close()
            arrowAnchorPanel = panel
            mbkLog("PopoverController", "openPopover -- hidden-menubar arrowAnchorPanel frame=\(panelRect) anchorX=\(anchorX)")
            // NSPanel.contentView is always non-nil (guaranteed by NSWindow contract).
            let contentView = panel.contentView!
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
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

    // MARK: - Window position pin

    /// Snapshots the popover window's top edge and subscribes to `didMove` and
    /// `didResize` notifications so that if AppKit repositions or resizes the window
    /// (e.g. during a scroll-view height change in hidden-menubar mode) we immediately
    /// recompute `origin.y = pinnedWindowMaxY - height` to keep the top edge fixed
    /// just below the menu bar.
    ///
    /// `pinnedWindowMaxY` is clamped to `screen.visibleFrame.maxY` so the popover
    /// never intrudes into the hidden menubar zone.
    ///
    /// Must be called after the popover frame has settled (i.e. from the async
    /// hop in `popoverDidShow`).
    func pinPopoverWindow() {
        // Guard against double-install: on rapid open→close→open the async Task hop
        // from the first popoverDidShow can fire after the second pinPopoverWindow()
        // has already registered observers, leaking the first token. Bail out if
        // observers are already in place — unpinPopoverWindow() always clears them
        // synchronously before this can be called for a new session.
        guard windowMoveObserver == nil, windowResizeObserver == nil else {
            mbkLog("PopoverController", "pinPopoverWindow -- already pinned, skipping")
            return
        }
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "pinPopoverWindow -- no window, skipping")
            return
        }
        let pinnedMaxY = window.screen?.visibleFrame.maxY
            ?? (window.frame.origin.y + window.frame.height)
        pinnedWindowMaxY = pinnedMaxY
        mbkLog("PopoverController", "pinPopoverWindow -- pinnedMaxY=\(pinnedMaxY) winFrame=\(window.frame)")

        let nc = NotificationCenter.default
        windowMoveObserver = nc.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // The Task hop is intentional and load-bearing: `handlePopoverWindowMoved`
            // calls `setFrameOrigin`, which synchronously re-fires `didMoveNotification`.
            // The async hop defers the handler to the next run-loop turn, breaking the
            // synchronous re-entrancy cycle. The epsilon guard in the handler then
            // suppresses any residual spurious correction.
            Task { @MainActor [weak self, weak window] in
                self?.handlePopoverWindowMoved(window: window)
            }
        }
        windowResizeObserver = nc.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // Same intentional Task hop as didMoveNotification — see above.
            Task { @MainActor [weak self, weak window] in
                self?.handlePopoverWindowMoved(window: window)
            }
        }
    }

    /// Called when the popover window moves or resizes.
    /// Recomputes the correct X as `lastKnownAnchorX - window.frame.width / 2`,
    /// snapped to the display pixel grid via `backingScaleFactor` so that
    /// `setFrameOrigin` produces a value AppKit will round to the same point,
    /// preventing a repeated sub-pixel correction loop on every resize event.
    /// Recomputes the correct Y as `pinnedWindowMaxY - window.frame.height`
    /// so the top edge stays fixed regardless of height changes.
    private func handlePopoverWindowMoved(window: NSWindow?) {
        guard popover.isShown,
              let window,
              let anchorX = lastKnownAnchorX else { return }
        let scale = window.backingScaleFactor
        let rawX = anchorX - window.frame.width / 2
        let correctX = scale > 0 ? (round(rawX * scale) / scale) : rawX
        let correctY = (pinnedWindowMaxY ?? (window.frame.origin.y + window.frame.height)) - window.frame.height
        // Epsilon guard (0.5pt): avoids a spurious correction when AppKit rounds
        // the frame to a pixel boundary that differs from our computed value by a
        // sub-pixel amount. 0.5pt is the finest grid AppKit uses (1× Retina);
        // any real drift caused by AppKit repositioning the window will be ≥1pt.
        guard abs(window.frame.minX - correctX) >= 0.5 || abs(window.frame.origin.y - correctY) >= 0.5 else { return }
        let driftedX = window.frame.minX
        let driftedY = window.frame.origin.y
        window.setFrameOrigin(NSPoint(x: correctX, y: correctY))
        mbkLog("PopoverController",
               "handlePopoverWindowMoved -- driftedX=\(driftedX) driftedY=\(driftedY) restoredX=\(correctX) restoredY=\(correctY) newFrame=\(window.frame)")
    }

    /// Removes the `didMove` and `didResize` observers, clears pinned state,
    /// and closes `arrowAnchorPanel` if still alive.
    /// Called from `popoverDidClose`.
    func unpinPopoverWindow() {
        let nc = NotificationCenter.default
        if let obs = windowMoveObserver { nc.removeObserver(obs) }
        if let obs = windowResizeObserver { nc.removeObserver(obs) }
        windowMoveObserver = nil
        windowResizeObserver = nil
        pinnedWindowMaxY = nil
        arrowAnchorPanel?.close()
        arrowAnchorPanel = nil
        mbkLog("PopoverController", "unpinPopoverWindow -- observers removed")
    }

    // MARK: - Panel / sheet helpers

    /// The `NSWindow` with `.nonactivatingPanel` style mask that is NOT `arrowAnchorPanel`.
    /// Used to find the sheet-hosting panel for `forceClose()`.
    var panelWindow: NSWindow? {
        NSApp.windows.first {
            $0.styleMask.contains(.nonactivatingPanel) && $0 !== arrowAnchorPanel
        }
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
    /// Arrow position in hidden-menubar mode is controlled by an invisible `NSPanel`
    /// (`arrowAnchorPanel`) positioned at `lastKnownAnchorX` in screen coordinates
    /// before `show()` — pure public API, no post-show correction needed.
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
