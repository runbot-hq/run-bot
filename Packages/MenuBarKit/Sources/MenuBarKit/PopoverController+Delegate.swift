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
    /// Highlights the status-bar button and sets `isShownSentinel` unconditionally
    /// to signal `applyContentSize` that the popover is open.
    ///
    /// Also snapshots chrome deltas (`hiddenChromeW/H`), `hiddenButtonMidX`, and
    /// `hiddenWindowY` here — the ONLY valid moment. `window.frame` is set by AppKit
    /// at show time; this is the only call where we can derive true chrome size and
    /// the correct fixed Y anchor. `applyContentSize` must NOT re-snapshot because
    /// by then `window.frame` reflects our own prior `setFrame`, not AppKit's.
    /// Chrome is constant across view switches (NSPopover window chrome never changes);
    /// `buttonMidX` and `windowY` are constant (button doesn't move, top edge of panel
    /// stays pinned under the button for the whole session).
    /// ❌ NEVER move this snapshot to `applyContentSize`.
    /// ❌ NEVER invalidate `hiddenChromeW/H/windowY` mid-session.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        isShownSentinel = true
        // Snapshot chrome deltas, buttonMidX, and windowY here — the ONLY valid moment.
        // window.frame is set by AppKit at show time; this is the only call where
        // we can derive true chrome size and the correct fixed Y anchor.
        // applyContentSize must NOT re-snapshot because by then window.frame reflects
        // our own prior setFrame, not AppKit's.
        // Chrome is constant across view switches (NSPopover window chrome never
        // changes); buttonMidX and windowY are constant (button doesn't move, top
        // edge of panel stays pinned under the button for the whole session).
        // ❌ NEVER move this snapshot to applyContentSize.
        // ❌ NEVER invalidate or recompute hiddenChromeW/H/windowY mid-session.
        if let window = hostingController.view.window,
           let button = statusItem.button,
           let buttonWin = button.window {
            hiddenChromeW   = window.frame.width  - popover.contentSize.width
            hiddenChromeH   = window.frame.height - popover.contentSize.height
            hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
            hiddenWindowY   = window.frame.origin.y
            mbkLog("PopoverController",
                   "popoverWillShow -- isShownSentinel=true chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!) btnMidX=\(hiddenButtonMidX!) windowY=\(hiddenWindowY!) win=\(window.frame) #\(window.windowNumber)")
        } else {
            mbkLog("PopoverController", "popoverWillShow -- isShownSentinel=true (no hostingWindow yet, chrome not snapshotted)")
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
    ///
    /// NOTE: this is the authoritative reset point for ALL gate flags, including
    /// `hasFilePickerOverlay`. `forceClose()` only clears `hasActiveOverlay` because
    /// it is structurally unreachable while `hasFilePickerOverlay` is true —
    /// the event monitor's `hasFilePicker` branch returns early before `forceClose`.
    /// Both flags are always cleared here regardless of which close path fired.
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
