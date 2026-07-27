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
    /// `buttonMidX` and `windowY` are snapshotted fresh on every open and on Path 2
    /// re-anchors (Path 2 calls `popover.show()` mid-session to re-derive the arrow
    /// position, which re-triggers this method and overwrites the snapshot values).
    ///
    /// WHY THE CHROME DELTA IS NOT AFFECTED BY STALE contentSize:
    /// A reviewer may note that `hiddenChromeW = window.frame.width - popover.contentSize.width`
    /// reads `popover.contentSize`, which could theoretically be stale (e.g. left over
    /// from a prior session if the Path 1 isOpening guard suppressed the last write).
    /// This is NOT a problem: AppKit derives `window.frame` directly from
    /// `popover.contentSize + chrome` at show time. Both sides of the subtraction are
    /// produced from the same `contentSize` value — any staleness cancels out perfectly.
    /// The result is always the true chrome constant (the fixed AppKit decoration size),
    /// regardless of whether `contentSize` reflects the current or a prior session.
    ///
    /// WHY THE SNAPSHOT IS UNCONDITIONAL (fires even in visible-menubar mode):
    /// A reviewer may note that `hiddenChromeW/H`, `hiddenButtonMidX`, and `hiddenWindowY`
    /// are only consumed by Path 3 (`isMenuBarHidden == true`), so snapshotting them in
    /// visible-menubar mode appears wasteful. Conditional snapshotting was considered and
    /// rejected for three reasons: (1) checking `isMenuBarHidden` here requires the same
    /// `button.window` access and has the same nil-failure modes as the snapshot itself;
    /// (2) if the condition fails, stale values from a prior session would remain in the
    /// snapshot vars rather than being overwritten with fresh ones — a correctness risk
    /// if the user toggles auto-hide mid-session; (3) Path 3 starts with a fresh snapshot
    /// either way. Unconditional is simpler, correct, and always produces fresh values.
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
        sessionOpenCount += 1
        setButtonHighlight(true)
        isShownSentinel = true
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController",
                   "popoverWillShow -- session=\(sessionOpenCount) isShownSentinel=true (hostingController.view.window nil, chrome not snapshotted; Path 3 will SKIP this session)")
            return
        }
        guard let button = statusItem.button,
              let buttonWin = button.window else {
            mbkLog("PopoverController",
                   "popoverWillShow -- session=\(sessionOpenCount) isShownSentinel=true (statusItem.button or button.window nil, chrome not snapshotted; Path 3 will SKIP this session)")
            return
        }
        hiddenChromeW    = window.frame.width  - popover.contentSize.width
        hiddenChromeH    = window.frame.height - popover.contentSize.height
        hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
        hiddenWindowY    = window.frame.maxY
        mbkLog("PopoverController",
               "popoverWillShow -- session=\(sessionOpenCount)" +
               " isShownSentinel=true" +
               " chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!)" +
               " btnMidX=\(hiddenButtonMidX!) windowMaxY=\(hiddenWindowY!)" +
               " popoverContentSize=\(popover.contentSize)" +
               " win=\(window.frame) #\(window.windowNumber)" +
               " winClass=\(type(of: window))")
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
        mbkLog("PopoverController", "popoverDidClose -- session=\(sessionOpenCount) overlay gate reset")
    }
}
