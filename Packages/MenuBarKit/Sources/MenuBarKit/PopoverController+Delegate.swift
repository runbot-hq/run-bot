// PopoverController+Delegate.swift
// MenuBarKit
//
// NSPopoverDelegate conformance for MBKPopoverController.

import AppKit

// MARK: - NSPopoverDelegate

/// `NSPopoverDelegate` conformance — show/close lifecycle and dismiss gating.
extension MBKPopoverController: NSPopoverDelegate {
    /// Snapshots chrome deltas, `buttonMidX`, and `windowY`; sets `isShownSentinel`.
    ///
    /// This is the **only** valid moment to snapshot chrome deltas and button geometry:
    /// `window.frame` is set by AppKit at show time, before any of our `setFrame` calls.
    /// `applyContentSize` must NOT snapshot because by then `window.frame` reflects our
    /// own prior `setFrame`, not AppKit's. Chrome is constant across view switches;
    /// `buttonMidX` and `windowY` are constant for the session.
    ///
    /// WHY `frame.maxY` AND NOT `frame.origin.y`:
    /// The popover window is small at snapshot time (initial contentSize, before SwiftUI
    /// has completed its first geometry pass). Snapshotting `origin.y` would capture the
    /// bottom edge of a small window — when Path 3 later reuses that Y for a much taller
    /// window, `origin.y` is too high and the popover appears near the top of the screen.
    /// Snapshotting `maxY` (the top edge) keeps the top of the popover pinned just below
    /// the status bar regardless of how tall the window grows. Path 3 derives `origin.y`
    /// as `hiddenWindowY - windowHeight` on every size change.
    ///
    /// ❌ NEVER move this snapshot to `applyContentSize`.
    /// ❌ NEVER invalidate `hiddenChromeW`/`H`/`windowY` mid-session.
    /// ❌ NEVER snapshot `frame.origin.y` here — use `frame.maxY`.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        isShownSentinel = true
        if let window = hostingController.view.window,
           let button = statusItem.button,
           let buttonWin = button.window {
            hiddenChromeW    = window.frame.width  - popover.contentSize.width
            hiddenChromeH    = window.frame.height - popover.contentSize.height
            hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
            hiddenWindowY    = window.frame.maxY
            mbkLog("PopoverController",
                   "popoverWillShow -- isShownSentinel=true" +
                   " chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!)" +
                   " btnMidX=\(hiddenButtonMidX!) windowMaxY=\(hiddenWindowY!)" +
                   " win=\(window.frame) #\(window.windowNumber)")
        } else {
            mbkLog("PopoverController",
                   "popoverWillShow -- isShownSentinel=true (no hostingWindow yet, chrome not snapshotted)")
        }
    }

    /// Blocks the popover from closing while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    /// Fires `onWillClose`, dehighlights the button, stops the event monitor,
    /// and resets all per-session state so the next open starts clean.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        isShownSentinel = nil
        isOpening = false
        hiddenChromeW = nil
        hiddenChromeH = nil
        hiddenButtonMidX = nil
        hiddenWindowY = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
