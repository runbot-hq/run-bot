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

    /// Pins the window position after AppKit has committed the popover frame.
    ///
    /// The `DispatchQueue.main.async` hop gives AppKit one full run-loop turn to
    /// complete its internal layout before we snapshot the window frame for pinning.
    ///
    /// Arrow placement is handled by the ephemeral `positioningView` subview
    /// passed to `show(relativeTo:of:preferredEdge:)` in `openPopover()` —
    /// no post-show correction is needed.
    public func popoverDidShow(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidShow")
        DispatchQueue.main.async { [weak self] in
            self?.pinPopoverWindow()
        }
    }

    /// Blocks the popover from closing while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    /// Fires `onWillClose`, dehighlights the button, stops the event monitor,
    /// resets per-session state, removes the window-pin observers, and removes
    /// the ephemeral positioning subview from the status-bar button.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        unpinPopoverWindow()
        removePositioningView()
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
