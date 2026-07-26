// PopoverController+Delegate.swift
// MenuBarKit
//
// NSPopoverDelegate conformance for MBKPopoverController.

import AppKit

extension MBKPopoverController: NSPopoverDelegate {
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
        // would corrupt hiddenChromeW/H/windowY for the rest of the session.
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
        hiddenWindowY    = window.frame.origin.y
        mbkLog("PopoverController",
               "popoverWillShow -- isShownSentinel=true chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!) btnMidX=\(hiddenButtonMidX!) windowY=\(hiddenWindowY!) win=\(window.frame) #\(window.windowNumber)")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

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
