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
    /// Handles `isOpening` suppression, `onWillShow`/`onDidShow` callbacks,
    /// and post-show X correction for the hidden-menubar case.
    func openPopover() {
        // Defensive reset: if a prior open attempt ran popover.show() but AppKit
        // silently rejected it (no popoverWillShow, no onDidShow, no popoverDidClose),
        // isOpening would be left permanently true. Resetting here ensures a clean
        // slate regardless of what happened in the previous cycle. The popoverDidClose
        // safety net covers the normal close path; this covers the degenerate no-show path.
        isOpening = false

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
        // Raise isOpening before show() so any applyContentSize calls that fire
        // between now and the onDidShow Task are suppressed. The onDidShow Task
        // lowers it after committing the authoritative geometry.
        isOpening = true
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

        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            // Lower isOpening before onDidShow fires so that any applyContentSize
            // call triggered by onDidShow (e.g. WRITE+REANCHOR from PanelMainView's
            // geometry pass) proceeds normally and commits the correct geometry.
            self.isOpening = false
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    // MARK: - Panel / sheet helpers

    /// The `NSWindow` with `.nonactivatingPanel` style mask, if any.
    /// This is the floating panel window that backs the popover.
    var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    /// `true` when the panel window has at least one child window (i.e. a sheet is attached).
    var hasSheetChildWindow: Bool {
        !(panelWindow?.childWindows ?? []).isEmpty
    }

    // MARK: - Close helpers

    /// Fires `onWillClose` exactly once per session, guarded by `onWillCloseFired`.
    /// `internal` (default) so `PopoverController+Delegate.swift` can access it.
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
    ///
    /// NOTE: `hasFilePickerOverlay` is intentionally NOT cleared here.
    /// The event monitor only reaches `forceClose()` when `hasFilePickerOverlay` is
    /// false — the `if hasFilePicker` branch fires first and returns early.
    /// This path is therefore structurally unreachable while `hasFilePickerOverlay`
    /// is true. `popoverDidClose` is the authoritative reset point for all gate
    /// flags and always fires after `performClose()`.
    ///
    /// ORDERING SAFETY — why performClose rejection is structurally impossible here:
    ///   forceClose() clears `overlayGate.hasActiveOverlay = false` BEFORE calling
    ///   `performClose(nil)`. Therefore `popoverShouldClose` will return `true` when
    ///   AppKit consults it, and the close will proceed. The `onWillCloseFired` guard
    ///   in `fireOnWillClose` is the sole protection against a double-fire if this
    ///   ordering is ever disturbed — do not reorder the gate clear and performClose
    ///   call without also reviewing that guard.
    func forceClose() {
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            // WHY WE DO NOT GUARD child ITERATION WITH child.isVisible:
            //   The TOCTOU race in MBKSheetAnchorTask (see AnchoredSheet.swift Known
            //   Limitations) can leave a dangling entry in pw.childWindows after the
            //   sheet has already been dismissed. A reviewer may be tempted to add
            //   `guard child.isVisible else { continue }` to skip it.
            //
            //   Do NOT do this. The reasons:
            //   1. `isVisible` returns `true` on a window that is animating out — the
            //      real sheet and a ghost entry are indistinguishable by `isVisible`
            //      alone at the moment forceClose fires.
            //   2. If the real sheet window happens to be `isVisible == false` (already
            //      hidden by SwiftUI before forceClose is called), skipping it would
            //      leave it attached as a child — the popover would fail to close or
            //      the orphaned window would leak.
            //   3. `addChildWindow(_:ordered:)` and `removeChildWindow(_:)` on an
            //      already-closing window are no-ops on macOS, so iterating and
            //      closing all children unconditionally is always safe.
            //   The correct fix for the ghost-entry problem, if it ever causes an
            //   observable issue, is to track the sheet NSWindow reference directly
            //   in MBKSheetAnchorTask and expose it for targeted removal — not to use
            //   `isVisible` as a heuristic discriminator here.
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
    /// `internal` (default) so `PopoverController+Delegate.swift` can access it.
    func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover / view setup

    /// Creates and configures the `NSPopover` with the hosted SwiftUI root view.
    func setupPopover() {
        hostingController = NSHostingController(rootView: wrapped(rootView))
        // MUST be []. Leaving this at the macOS default (.preferredContentSize)
        // makes AppKit auto-write contentSize from the SwiftUI view's live
        // intrinsic size on every layout pass — a second, competing write path
        // that races our own applyContentSize() call.
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Wraps `view` in a `GeometryReader` background that calls `applyContentSize`
    /// on every SwiftUI layout pass and on first appear.
    /// This is the sole mechanism by which SwiftUI reports its preferred size.
    func wrapped(_ view: AnyView) -> AnyView {
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

    /// Clamps `size` to `[minWidth, maxWidth] × [0, maxHeight]`.
    func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }
}
