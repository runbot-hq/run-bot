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
            // hostingController.view.frame.size is the actual rendered size of the
            // SwiftUI content view inside the window and is immune to the race.
            if hiddenChromeW == nil,
               let button = statusItem.button,
               let buttonWin = button.window {
                let actualContentSize = hostingController.view.frame.size
                hiddenChromeW = window.frame.width  - actualContentSize.width
                hiddenChromeH = window.frame.height - actualContentSize.height
                hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
                // Seed hiddenLastSetWidth from the actual content so Guard 3 has a
                // valid baseline on the very first Path 3 call.
                hiddenLastSetWidth = actualContentSize.width
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
            // Guard 3: discard stale departing-view GR fires in hidden mode.
            //
            // Identical problem to Guard 2 in Path 2: when the user navigates
            // main -> settings while the menubar is hidden, the sequence is:
            //   (a) settings GR fires 480x551 -> DIRECT FRAME 480x551  (correct)
            //   (b) departing main-view GR fires 642.5xN -> DIRECT FRAME back
            //       to main dimensions, overwriting the correct settings frame
            //
            // Path 3 never writes popover.contentSize so oldWidth (derived from
            // popover.contentSize) is not a reliable reference. Instead track the
            // last width actually committed to the window in hiddenLastSetWidth.
            // A report whose width is narrower than the last committed width is a
            // stale departing-view write and must be discarded.
            //
            // Note the direction is OPPOSITE to Guard 2: in hidden mode navigation
            // goes main (wide) -> settings (narrow), so the stale write is the
            // main-view GR firing AFTER settings has already been set. We discard
            // any write where clamped.width > hiddenLastSetWidth + 1 AND
            // hiddenLastSetWidth is already at settings width (i.e., a width
            // increase mid-navigation).
            //
            // Actually the simpler invariant: discard any width-change write that
            // WIDENS the window when we are not in the opening sequence, because
            // the live view (settings at 480) never grows wider spontaneously —
            // only the departing main-view GR does.
            if let lastW = hiddenLastSetWidth,
               clamped.width > lastW + 1,
               !isOpening {
                mbkLog("PopoverController",
                       "applyContentSize -- hidden, width widened mid-nav (\(lastW) -> \(clamped.width)), SKIP, stale departing main-view GR discarded")
                return
            }
            let newW = clamped.width + chromeW
            let newH = clamped.height + chromeH
            let newX = btnMidX - newW / 2
            let newY = window.frame.origin.y + (window.frame.height - newH)
            let newFrame = NSRect(x: newX, y: newY, width: newW, height: newH)
            window.setFrame(newFrame, display: true)
            hiddenLastSetWidth = clamped.width
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
                // mid-session. SKIP entirely — no contentSize write — so contentSize
                // stays at the authoritative width for a clean dedup on the next
                // genuine navigation.
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
