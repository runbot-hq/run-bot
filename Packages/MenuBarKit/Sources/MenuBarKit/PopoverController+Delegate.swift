// PopoverController+Delegate.swift
// MenuBarKit
//
// NSPopoverDelegate conformance for MBKPopoverController.

import AppKit

// MARK: - NSPopoverDelegate

/// `NSPopoverDelegate` conformance — show/close lifecycle and dismiss gating.
extension MBKPopoverController: NSPopoverDelegate {

    /// Highlights the status-bar button on show.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        mbkLog("PopoverController", "popoverWillShow")
    }

    /// Corrects the arrow anchor point after AppKit has committed the popover frame.
    ///
    /// The `DispatchQueue.main.async` hop gives AppKit one full run-loop turn to
    /// complete its internal `_updateAnchorPointForFrame:reshape:` call before we
    /// write `anchorPoint`. Writing synchronously here (or from a KVO on contentSize)
    /// loses the race — AppKit's layout pass runs after our write and resets
    /// `anchorPoint` to `(0, 0)`.
    public func popoverDidShow(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidShow")
        DispatchQueue.main.async { [weak self] in
            self?.correctArrowAnchorPoint()
        }
    }

    /// Blocks the popover from closing while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    /// Fires `onWillClose`, dehighlights the button, stops the event monitor,
    /// and resets per-session state.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
