// PopoverController+Delegate.swift
// MenuBarKit
//
// NSPopoverDelegate conformance for MBKPopoverController.

import AppKit

extension MBKPopoverController: NSPopoverDelegate {
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
