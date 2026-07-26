// PopoverController+ContentSize.swift
// MenuBarKit
//
// SwiftUI-reported content size application for MBKPopoverController.
// See PopoverController.swift file header for full design notes.

import AppKit

/// SwiftUI-reported content size application for `MBKPopoverController`.
extension MBKPopoverController {

    // MARK: - applyContentSize

    /// Applies a SwiftUI-reported preferred size to the popover or its backing window.
    ///
    /// Three paths: (1) not shown — write `contentSize` so it opens at the right size;
    /// (2) shown, menubar visible — write `contentSize`, re-anchor via `show()` on width
    /// change so AppKit re-derives the arrow position atomically; (3) shown, menubar
    /// hidden — `NSPopover.contentSize` is ignored by AppKit, so drive `window.setFrame`
    /// directly using snapshotted chrome deltas and `buttonMidX`.
    func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }

        guard popover.isShown,
              let window = hostingController.view.window,
              isShownSentinel != nil else {
            // Path 1: not shown (or sentinel not yet set).
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        let oldWidth = popover.contentSize.width
        let widthChanged = abs(clamped.width - oldWidth) > 1

        if isMenuBarHidden {
            // Path 3: hidden mode — NSPopover ignores setContentSize here.
            //
            // Snapshot chrome deltas once per hidden session.
            //
            // IMPORTANT: use hostingController.view.frame.size, NOT popover.contentSize.
            // Post-close Path 1 writes race to update popover.contentSize before the
            // hidden session begins. By the time the first Path 3 call arrives, the
            // window frame still reflects the last visible content size, but
            // popover.contentSize has already been overwritten by post-close GR fires.
            // Using popover.contentSize produces a wildly wrong chromeH delta
            // (e.g. 733 - 372 = 361 instead of the correct 733 - 707 = 26).
            // hostingController.view.frame.size is the actual rendered size of the
            // SwiftUI content view inside the window and is not affected by the race.
            if hiddenChromeW == nil,
               let button = statusItem.button,
               let buttonWin = button.window {
                let actualContentSize = hostingController.view.frame.size
                hiddenChromeW = window.frame.width  - actualContentSize.width
                hiddenChromeH = window.frame.height - actualContentSize.height
                hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
                mbkLog("PopoverController",
                       "applyContentSize -- hidden snapshot actualContent=(\(actualContentSize.width),\(actualContentSize.height)) chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!) buttonMidX=\(hiddenButtonMidX!)")
            }
            guard let chromeW = hiddenChromeW,
                  let chromeH = hiddenChromeH,
                  let btnMidX = hiddenButtonMidX else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no chrome snapshot yet, SKIP (\(clamped.width),\(clamped.height))")
                return
            }
            let newW = clamped.width + chromeW
            let newH = clamped.height + chromeH
            let newX = btnMidX - newW / 2
            let newY = window.frame.origin.y + (window.frame.height - newH)
            let newFrame = NSRect(x: newX, y: newY, width: newW, height: newH)
            window.setFrame(newFrame, display: true)
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, DIRECT FRAME (\(clamped.width),\(clamped.height)) btnMidX=\(btnMidX) frame=\(newFrame)")
        } else {
            // Path 2: menubar visible.
            if isClosing {
                mbkLog("PopoverController",
                       "applyContentSize -- closing in flight, SKIP WRITE+REANCHOR (\(clamped.width),\(clamped.height))")
                return
            }
            if widthChanged {
                // Guard 2: discard stale departing-view GR fires where width narrows
                // mid-session (settings GR fires 480 after main view has remounted).
                // SKIP entirely — no contentSize write — so contentSize stays at the
                // authoritative main-view width for a clean dedup on the next genuine
                // settings navigation.
                if clamped.width < oldWidth - 1 && !isOpening {
                    mbkLog("PopoverController",
                           "applyContentSize -- width narrowed mid-session (\(oldWidth) -> \(clamped.width)), SKIP entirely, stale departing-view GR discarded")
                    return
                }
                popover.contentSize = clamped
                guard let button = statusItem.button,
                      let rect = positioningRect(for: button) else {
                    mbkLog("PopoverController",
                           "applyContentSize -- WRITE only, button unavailable for re-anchor (\(clamped.width),\(clamped.height))")
                    return
                }
                if let anchorX = buttonScreenMidX { lastKnownAnchorX = anchorX }
                popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE+REANCHOR via show() (\(clamped.width),\(clamped.height))")
            } else {
                popover.contentSize = clamped
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE only, height-only change (\(clamped.width),\(clamped.height))")
            }
        }
    }
}
