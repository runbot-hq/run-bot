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
    /// `isShownSentinel` is set before the window check so that a nil
    /// `hostingController.view.window` — theoretically possible if SwiftUI hasn't
    /// yet attached its view, not observed in practice on macOS 13+ — does not
    /// prevent the sentinel from being armed. Without the sentinel, `applyContentSize`
    /// would fall through to Path 1 for the entire session, writing `contentSize`
    /// instead of driving the window frame directly — a silent correctness failure
    /// in the hidden-menubar path.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        isShownSentinel = true
        if let window = hostingController.view.window {
            mbkLog("PopoverController",
                   "popoverWillShow -- isShownSentinel=true win=\(window.frame) #\(window.windowNumber)")
        } else {
            mbkLog("PopoverController", "popoverWillShow -- isShownSentinel=true (no hostingWindow yet)")
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
        // Reset all per-session state so the next open starts clean.
        // NOTE: this is the authoritative reset point for ALL gate flags, including
        // hasFilePickerOverlay. forceClose() only clears hasActiveOverlay because
        // it is structurally unreachable while hasFilePickerOverlay is true —
        // the event monitor's hasFilePicker branch returns early before forceClose.
        // Both flags are always cleared here regardless of which close path fired.
        isShownSentinel = nil
        isOpening = false
        hiddenChromeW = nil
        hiddenChromeH = nil
        hiddenButtonMidX = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
