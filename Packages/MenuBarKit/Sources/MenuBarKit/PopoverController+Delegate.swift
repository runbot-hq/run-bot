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
    /// ❌ NEVER move this snapshot to `applyContentSize`.
    /// ❌ NEVER invalidate `hiddenChromeW`/`H`/`windowY` mid-session.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        isShownSentinel = true
        if let window = hostingController.view.window,
           let button = statusItem.button,
           let buttonWin = button.window {
            hiddenChromeW    = window.frame.width  - popover.contentSize.width
            hiddenChromeH    = window.frame.height - popover.contentSize.height
            hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
            hiddenWindowY    = window.frame.origin.y
            mbkLog("PopoverController",
                   "popoverWillShow -- isShownSentinel=true" +
                   " chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!)" +
                   " btnMidX=\(hiddenButtonMidX!) windowY=\(hiddenWindowY!)" +
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
