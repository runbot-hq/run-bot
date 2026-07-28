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
    ///
    /// frame.height vs frame.maxY: the comparison uses `screenFrame.height` rather
    /// than `screenFrame.maxY`. On the primary display (origin at 0,0) these are
    /// identical. On secondary displays with a non-zero screen origin they differ.
    /// This app is a menu-bar app — the status item always lives on the primary
    /// display's menu bar, so `button.window` is always on the primary display
    /// where origin.y == 0 and frame.height == frame.maxY. A secondary-display
    /// correction would add complexity with no real-world benefit.
    ///
    /// screenFrame == .zero transient: `buttonWin.screen` can return a valid NSScreen
    /// whose `.frame` is transiently (0,0,0,0) during a display reconfiguration event
    /// (e.g. display sleep/wake, resolution change). In that state screenH = -1 and
    /// hidden = true. On first-ever open `lastKnownAnchorX` is nil so `openPopover()`
    /// falls through to the visible path — safe. On a subsequent open it would use a
    /// stale `lastKnownAnchorX` with the ghost panel, which may produce a briefly
    /// misplaced popover until the next real open updates the anchor. This is a
    /// transient cosmetic edge case with no data loss; no fix is applied.
    var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        guard let buttonWin = button.window else {
            mbkLog("PopoverController", "isMenuBarHidden -- button.window is nil, treating as hidden")
            return true
        }
        let buttonScreen = buttonWin.screen
        let screenFrame = buttonScreen?.frame ?? .zero
        // This app is a menu-bar app — the status item always lives on the primary
        // display where origin.y == 0, making screenFrame.height == screenFrame.maxY.
        // Assert the invariant so a future multi-display topology surfaces immediately
        // rather than silently misbehaving in the height comparison below.
        assert(screenFrame == .zero || screenFrame.origin.y == 0,
               "isMenuBarHidden: primary display has non-zero Y origin — height/maxY comparison is wrong")
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
    ///
    /// lastKnownAnchorX is updated unconditionally before the hidden-mode branch:
    /// only the button window's Y is stale when the bar is hidden (the bar slides
    /// vertically off-screen). The horizontal position (frame.minX) stays valid,
    /// so reading it in hidden mode is safe and keeps the value current.
    func openPopover() {
        guard let button = statusItem.button else { return }
        // Cache button.window once — isMenuBarHidden and buttonScreenMidX each read
        // button.window internally, and the ghost-panel branch reads it a third time.
        // All reads are @MainActor-safe; caching removes the redundancy and makes the
        // nil-fallback path in the ghost-panel branch explicit.
        let buttonWin = button.window
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        if menuBarHidden, let anchorX = lastKnownAnchorX, let screen = buttonWin?.screen ?? NSScreen.main {
            // Close any stale panel before creating a new one so that the old reference
            // is never in NSApp.windows simultaneously with the new panel.
            // Normally unpinPopoverWindow() closes it in popoverDidClose, but on a
            // rapid re-open race the old panel could still be alive here.
            arrowAnchorPanel?.close()
            arrowAnchorPanel = nil
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
            arrowAnchorPanel = panel
            // isPinnedForHiddenMode is set here, before show() and before pinPopoverWindow()
            // installs its observers. There is no race: handlePopoverWindowMoved is only
            // reachable via the didMove/didResize observers, which are not installed until
            // pinPopoverWindow() runs from the popoverDidShow Task hop. Setting the flag
            // early is necessary so the Task in popoverDidShow sees the correct mode
            // before deciding whether to call pinPopoverWindow().
            isPinnedForHiddenMode = true
            mbkLog("PopoverController", "openPopover -- hidden-menubar arrowAnchorPanel frame=\(panelRect) anchorX=\(anchorX)")
            // NSPanel.contentView is always non-nil (guaranteed by NSWindow contract).
            let contentView = panel.contentView!
            popover.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        } else {
            isPinnedForHiddenMode = false
            guard let posRect = positioningRect(for: button) else { return }
            mbkLog("PopoverController", "openPopover -- visible-menubar posRect=\(posRect)")
            popover.show(relativeTo: posRect, of: button, preferredEdge: .minY)
        }

        // NSApp.activate(ignoringOtherApps:) is deprecated in macOS 14, but there is no
        // drop-in replacement for menu-bar apps. The modern NSApplication.activate() (no
        // parameter) is a no-op when the activation policy is .accessory, which is what
        // this app uses. ignoringOtherApps: true is the only call that reliably focuses
        // the popover's text fields and key window on all supported OS versions.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown -- window frame=\(hostingController.view.window?.frame ?? .zero)")

        startEventMonitor()

        Task { @MainActor [weak self] in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            guard self?.popover.isShown == true else {
                mbkLog("PopoverController", "onDidShow Task hop -- popover already closed, skipping onDidShow")
                return
            }
            self?.onDidShow?()
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
    /// `pinnedWindowMaxY` is snapshotted from `window.frame.maxY` — the actual top
    /// edge AppKit placed the window at after show(). Using screen.visibleFrame.maxY
    /// instead causes a 1pt mismatch: the arrowAnchorPanel sits at visibleFrame.maxY-1
    /// so AppKit places the popover top at 949 while the pin would target 950,
    /// producing a visible 1pt snap on every resize.
    ///
    /// Must be called after the popover frame has settled (i.e. from the async
    /// hop in `popoverDidShow`).
    func pinPopoverWindow() {
        // Guard against double-install.
        //
        // Scenario: rapid open → close → reopen.
        //   Session 1: popoverDidShow fires → async Task queued → popoverDidClose fires
        //              → unpinPopoverWindow() clears observers (windowMoveObserver = nil).
        //   Session 2: popoverDidShow fires → pinPopoverWindow() installs observers.
        //   Session 1 Task: now fires → hits this guard → observers already in place
        //              → bails out correctly.
        //
        // The opposite race (session 1 Task fires after session 2's popoverDidClose
        // has already nilled the observers) cannot produce a harmful install: if
        // session 2 is fully closed, isPinnedForHiddenMode is false and
        // handlePopoverWindowMoved is a no-op regardless. The leaked token (if any)
        // is on a deallocated window object and will never fire.
        //
        // Both orderings are safe because all paths run on @MainActor — there is no
        // concurrent mutation of windowMoveObserver / windowResizeObserver.
        guard windowMoveObserver == nil, windowResizeObserver == nil else {
            mbkLog("PopoverController", "pinPopoverWindow -- stale async task hop after close, skipping")
            return
        }
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "pinPopoverWindow -- no window, skipping")
            return
        }
        // Use window.frame.maxY — the actual top edge AppKit placed the window at.
        // Do NOT use screen.visibleFrame.maxY: the arrowAnchorPanel is positioned at
        // visibleFrame.maxY - 1, so AppKit places the popover top at that value (e.g.
        // 949), not at visibleFrame.maxY (950). Pinning to the screen boundary instead
        // of the real frame causes a 1pt Y correction on every resize, visible as jitter.
        let pinnedMaxY = window.frame.maxY
        pinnedWindowMaxY = pinnedMaxY
        mbkLog("PopoverController", "pinPopoverWindow -- pinnedMaxY=\(pinnedMaxY) winFrame=\(window.frame)")

        let nc = NotificationCenter.default
        windowMoveObserver = nc.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // The Task hop is required for Swift 6 @MainActor isolation.
            // setFrameOrigin (called inside handlePopoverWindowMoved) synchronously
            // re-fires didMoveNotification on the same run-loop turn. Without the
            // isCorrectingFrame guard in the handler, this would produce a loop:
            // move → Task enqueued → AppKit moves window → Task fires → correction
            // → move → Task enqueued → … with the Y drifting on every cycle.
            // isCorrectingFrame is set true before setFrameOrigin and cleared after,
            // so the Task fired by our own correction bails immediately at entry.
            Task { @MainActor [weak self, weak window] in
                self?.handlePopoverWindowMoved(window: window)
            }
        }
        windowResizeObserver = nc.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            // Same isCorrectingFrame guard applies — see didMoveNotification above.
            Task { @MainActor [weak self, weak window] in
                self?.handlePopoverWindowMoved(window: window)
            }
        }
    }

    /// Called when the popover window moves or resizes.
    /// Only corrects position when `isPinnedForHiddenMode` is `true` — in
    /// visible-menubar mode AppKit owns the window position and this handler
    /// must not interfere with its own popover-placement logic.
    /// Recomputes the correct X as `lastKnownAnchorX - window.frame.width / 2`,
    /// snapped to the display pixel grid via `backingScaleFactor` so that
    /// `setFrameOrigin` produces a value AppKit will round to the same point,
    /// preventing a repeated sub-pixel correction loop on every resize event.
    /// Recomputes the correct Y as `pinnedWindowMaxY - window.frame.height`
    /// so the top edge stays fixed regardless of height changes.
    ///
    /// isCorrectingFrame guard: `setFrameOrigin` synchronously fires
    /// `didMoveNotification`, which enqueues a new Task (via the observer closure).
    /// That Task would re-enter this function on the next run-loop turn and see the
    /// window already at the correct position — but only if AppKit has not moved it
    /// again in the meantime. If AppKit does move it (e.g. during a content resize)
    /// the epsilon guard alone is not enough because the Task delay gives AppKit time
    /// to produce a new drift ≥0.5pt before the guard fires. The isCorrectingFrame
    /// flag solves this at the source: while we are calling setFrameOrigin, any
    /// Task that fires as a result of our own correction bails immediately, regardless
    /// of what AppKit did between enqueue and fire.
    private func handlePopoverWindowMoved(window: NSWindow?) {
        guard isPinnedForHiddenMode,
              popover.isShown,
              let window,
              let anchorX = lastKnownAnchorX else { return }
        // Bail if this call was triggered by our own setFrameOrigin below.
        // Without this guard the Task hop (required for Swift 6 isolation) creates
        // a Y-jump loop: setFrameOrigin → didMove → Task → handler → setFrameOrigin → …
        guard !isCorrectingFrame else {
            mbkLog("PopoverController", "handlePopoverWindowMoved -- re-entrant call from own correction, skipping")
            return
        }
        guard let pinnedMaxY = pinnedWindowMaxY else {
            // pinnedWindowMaxY is nil only if pinPopoverWindow() bailed at the no-window
            // guard, in which case no observers were installed and this handler cannot
            // legitimately fire. Log and bail rather than computing a no-op correction.
            mbkLog("PopoverController", "handlePopoverWindowMoved -- pinnedWindowMaxY is nil, skipping")
            return
        }
        let scale = window.backingScaleFactor
        let rawX = anchorX - window.frame.width / 2
        let correctX = scale > 0 ? (round(rawX * scale) / scale) : rawX
        let correctY = pinnedMaxY - window.frame.height
        // Epsilon guard (0.5pt): avoids a spurious correction when AppKit rounds
        // the frame to a pixel boundary that differs from our computed value by a
        // sub-pixel amount. 0.5pt is the finest grid AppKit uses (1× Retina);
        // any real drift caused by AppKit repositioning the window will be ≥1pt.
        guard abs(window.frame.minX - correctX) >= 0.5 || abs(window.frame.origin.y - correctY) >= 0.5 else { return }
        let driftedX = window.frame.minX
        let driftedY = window.frame.origin.y
        isCorrectingFrame = true
        window.setFrameOrigin(NSPoint(x: correctX, y: correctY))
        isCorrectingFrame = false
        mbkLog("PopoverController",
               "handlePopoverWindowMoved -- driftedX=\(driftedX) driftedY=\(driftedY) restoredX=\(correctX) restoredY=\(correctY) newFrame=\(window.frame)")
    }

    /// Removes the `didMove` and `didResize` observers, clears pinned state,
    /// and closes `arrowAnchorPanel` if still alive.
    /// Called from `popoverDidClose`.
    ///
    /// arrowAnchorPanel is closed here (not in openPopover or earlier) because
    /// AppKit holds a weak reference to the positioningView's window internally.
    /// Closing the panel before popoverDidClose fires causes AppKit to lose the
    /// anchor and snap the popover origin to (0, y) on the next content resize.
    func unpinPopoverWindow() {
        let nc = NotificationCenter.default
        if let obs = windowMoveObserver { nc.removeObserver(obs) }
        if let obs = windowResizeObserver { nc.removeObserver(obs) }
        windowMoveObserver = nil
        windowResizeObserver = nil
        pinnedWindowMaxY = nil
        isPinnedForHiddenMode = false
        isCorrectingFrame = false
        arrowAnchorPanel?.close()
        arrowAnchorPanel = nil
        mbkLog("PopoverController", "unpinPopoverWindow -- observers removed")
    }

    // MARK: - Panel / sheet helpers

    /// The `NSWindow` with `.nonactivatingPanel` style mask that is NOT `arrowAnchorPanel`.
    /// Used to find the sheet-hosting panel for `forceClose()`.
    ///
    /// Why NSApp.windows scan instead of a stored reference: AppKit does not
    /// guarantee that `hostingController.view.window` is stable across the popover
    /// lifecycle — it can be reassigned by AppKit between popoverWillShow and
    /// popoverDidShow. The arrowAnchorPanel exclusion (identity check) is the
    /// discriminator: arrowAnchorPanel is the only other nonactivatingPanel window
    /// this controller ever creates, so the scan is unambiguous for this app's
    /// window topology. If the host app introduces additional nonactivatingPanel
    /// windows, this property would need to be replaced with a stored reference
    /// captured in popoverDidShow.
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
