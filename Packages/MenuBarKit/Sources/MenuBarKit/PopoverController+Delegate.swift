// PopoverController+Delegate.swift
// MenuBarKit
//
// NSPopoverDelegate conformance for MBKPopoverController.
// Split into its own file to keep PopoverController.swift within the
// SwiftLint file_length limit (620 lines).

import AppKit

// MARK: - NSPopoverDelegate

/// `NSPopoverDelegate` conformance — show/close lifecycle and dismiss gating.
extension MBKPopoverController: NSPopoverDelegate {
    /// Highlights the status-bar button, arms `isShownSentinel`, and snapshots
    /// hidden-mode chrome deltas (`hiddenChromeW/H`, `hiddenButtonMidX`,
    /// `hiddenWindowTopY`) once per open/close cycle.
    ///
    /// `isShownSentinel` is set before the window-availability check so that a
    /// nil `hostingController.view.window` does not prevent it from being armed.
    /// Chrome values are snapshotted only when `hiddenChromeW == nil` (i.e. the
    /// first `popoverWillShow` call of a session) — re-anchor `show()` calls from
    /// Path 2 are skipped. See the inline comments for the full ordering rationale.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        isShownSentinel = true
        // Chrome snapshot — first open only (hiddenChromeW == nil).
        //
        // This delegate fires on EVERY popover.show() call, including mid-session
        // WRITE+REANCHOR calls from Path 2 (width change). By the time those fire,
        // window.frame reflects either our own prior setFrame (hidden mode) or
        // AppKit's post-contentSize-write position (visible mode) — neither is the
        // clean AppKit-positioned frame from the initial open. Re-snapshotting there
        // would corrupt hiddenChromeW/H/windowTopY for the rest of the session.
        //
        // hiddenChromeW is nil only after popoverDidClose (or before first open).
        // The guard ensures we snapshot exactly once per open/close cycle, against
        // AppKit's own frame, before any of our writes touch window.frame.
        //
        // ORDERING NOTE: isOpening is raised before popover.show() in openPopover()
        // and is therefore already true when this first fires. The snapshot doesn't
        // check isOpening — it doesn't need to. The hiddenChromeW == nil guard is
        // the sole correct discriminator between first-open and re-anchor calls.
        // ❌ Do NOT replace this guard with an isOpening check — isOpening is also
        //    true on re-anchor show() calls when a Task hop hasn't landed yet.
        //
        // WHY THE SNAPSHOT IS CORRECT EVEN THOUGH contentSize WAS JUST RESET TO
        // (minWidth, 100):
        // openPopover() resets popover.contentSize = (minWidth, 100) before calling
        // show(). AppKit immediately sizes window.frame to match that contentSize
        // before show() returns (and before popoverWillShow fires). So at snapshot
        // time: window.frame.width = minWidth + chrome. Therefore:
        //   hiddenChromeW = window.frame.width - popover.contentSize.width
        //              = (minWidth + chrome) - minWidth
        //              = chrome  ✅
        // Chrome is a constant property of the NSPopover window decoration —
        // independent of which contentSize value triggered the frame sizing.
        // The stub reset does not affect the correctness of the delta.
        //
        // WHY hiddenWindowTopY = window.frame.maxY (NOT origin.y):
        // The window is stub-sized at snapshot time (~126pt tall: 100 content +
        // 26 chrome). Path 3 grows the window as SwiftUI measures real content.
        // If we stored origin.y (bottom edge), the bottom would stay fixed and the
        // top would rise off-screen as the panel grows. Storing maxY (top edge)
        // lets Path 3 derive newOriginY = topY - newHeight, pinning the top edge
        // just below the button and growing the panel downward. ❌ NEVER change
        // this to window.frame.origin.y.
        guard hiddenChromeW == nil,
              let window = hostingController.view.window,
              let button = statusItem.button,
              let buttonWin = button.window else {
            if hiddenChromeW != nil {
                mbkLog("PopoverController",
                       "popoverWillShow -- re-anchor call, chrome already snapshotted, skipping")
            } else {
                mbkLog("PopoverController",
                       "popoverWillShow -- isShownSentinel=true (no hostingWindow yet, chrome not snapshotted)")
            }
            return
        }
        hiddenChromeW    = window.frame.width  - popover.contentSize.width
        hiddenChromeH    = window.frame.height - popover.contentSize.height
        hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
        hiddenWindowTopY = window.frame.maxY
        mbkLog("PopoverController",
               "popoverWillShow -- isShownSentinel=true chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!)" +
               " btnMidX=\(hiddenButtonMidX!) windowTopY=\(hiddenWindowTopY!) win=\(window.frame)" +
               " #\(window.windowNumber)")
    }

    /// Blocks the popover from closing while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    /// Fires `onWillClose`, dehighlights the button, stops the event monitor,
    /// resets all per-session state, and clears the overlay gate so the next
    /// open starts clean.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        isShownSentinel = nil
        // DEFENSIVE: isOpening is lowered in the onDidShow Task before any close
        // can occur, so this reset is structurally unreachable under normal flow.
        // Kept as a safety net against any future path (e.g. show() failing silently,
        // or a MBK change that skips onDidShow) where isOpening could be left dirty.
        // ❌ NEVER remove on the grounds that it is "unreachable" — that reasoning
        //    is load-bearing on the current open/close ordering remaining stable.
        isOpening = false
        hiddenChromeW = nil
        hiddenChromeH = nil
        hiddenButtonMidX = nil
        hiddenWindowTopY = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
