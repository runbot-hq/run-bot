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

    /// Pins the popover window position after AppKit has committed the frame.
    ///
    /// The `Task { @MainActor in }` hop gives AppKit one full run-loop turn to
    /// complete its internal layout pass before we snapshot the frame in
    /// `pinPopoverWindow()`. The pin must be in place before any subsequent
    /// resize or move notification can fire.
    ///
    /// Fast-close guard: if the popover is closed within that one run-loop turn
    /// (rapid double-click, or a programmatic close in tests), `popoverDidClose`
    /// fires first and `unpinPopoverWindow()` runs as a no-op (observers not yet
    /// installed). Without the guard below, the Task would then install observers
    /// on a dead session. On the next open, `pinPopoverWindow()`'s double-install
    /// guard would fire on the stale non-nil tokens and skip re-registration,
    /// leaving the new session entirely unpinned.
    public func popoverDidShow(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidShow")
        Task { @MainActor [weak self] in
            guard self?.popover.isShown == true else {
                mbkLog("PopoverController", "popoverDidShow Task -- popover already closed, skipping pinPopoverWindow")
                return
            }
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
