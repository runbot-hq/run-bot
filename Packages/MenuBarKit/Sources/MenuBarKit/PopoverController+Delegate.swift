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

    /// Pins the window X after AppKit has committed the popover frame.
    ///
    /// Arrow correction is intentionally NOT called here. AppKit immediately
    /// resizes and repositions the window after `popoverDidShow` fires (to
    /// accommodate SwiftUI's preferred content size), which means
    /// `correctArrowAnchorPoint()` would run on the wrong (pre-resize) frame.
    /// `handlePopoverWindowMoved` fires on the final settled frame and owns
    /// arrow correction from there.
    ///
    /// `pinPopoverWindow()` is called in a `DispatchQueue.main.async` hop so
    /// the pin is in place before any subsequent resize or move notification
    /// can fire.
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
    /// resets per-session state, and removes the window-pin observers.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        unpinPopoverWindow()
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
