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

        // isShownSentinel is set unconditionally in popoverWillShow (before show()
        // returns) and cleared in popoverDidClose. If the popover is shown but the
        // sentinel is still nil, the window was not yet available at popoverWillShow
        // time — an extremely unlikely race on macOS 13+, but handled safely by
        // falling through to Path 1 (contentSize write only), which is always safe.
        // Path 1 also fires for normal pre-open size callbacks.
        guard popover.isShown,
              let window = hostingController.view.window,
              isShownSentinel != nil else {
            // Path 1: not shown (or sentinel not yet set).
            //
            // NOTE: the isMenuBarHidden guard that previously existed here has been
            // removed. Writing contentSize while the popover is closed is always inert
            // — AppKit ignores the value until the next show() call. The concern that
            // motivated the guard ("poisons the X anchor") only applies to show() calls,
            // not to plain contentSize writes. Blocking these writes caused contentSize
            // to retain the stale settings-view size through the hidden period, so the
            // next open flashed at the wrong dimensions (root cause 1 of #2280).
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
            // Snapshot chrome deltas and buttonMidX once per hidden session so
            // every frame write re-centers correctly regardless of which view
            // is active or how many times width changes.
            if hiddenChromeW == nil,
               let button = statusItem.button,
               let buttonWin = button.window {
                hiddenChromeW = window.frame.width - popover.contentSize.width
                hiddenChromeH = window.frame.height - popover.contentSize.height
                hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
                mbkLog("PopoverController",
                       "applyContentSize -- hidden snapshot chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!) buttonMidX=\(hiddenButtonMidX!)")
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
            // ❌ DO NOT use window.frame.origin.x as a fixed left edge here —
            // it was computed for a specific width and is wrong for any other width.
            // Always derive originX from btnMidX so main and settings (which have
            // different widths) both land centred under the status item.
            let newX = btnMidX - newW / 2  // re-centre on the status item for every write
            // Anchor from current bottom edge upward — self-contained, no isShownSentinel needed.
            let newY = window.frame.origin.y + (window.frame.height - newH)
            let newFrame = NSRect(x: newX, y: newY, width: newW, height: newH)
            window.setFrame(newFrame, display: true)
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, DIRECT FRAME (\(clamped.width),\(clamped.height)) btnMidX=\(btnMidX) frame=\(newFrame)")
        } else {
            // Path 2: menubar visible — write contentSize then re-anchor via show()
            // on width change so AppKit re-derives arrow position atomically.
            //
            // NOTE: show() re-triggers popoverWillShow (and all NSPopoverDelegate
            // methods). setButtonHighlight(true) and isShownSentinel = true are
            // idempotent no-ops on a second call within the same session. If
            // delegate logic is ever added that must not fire twice per open,
            // this call site must be audited first.
            //
            // GUARDED (1): skip entirely while the closing sequence is in flight
            // (isClosing == true). fireOnWillClose() raises isClosing before
            // onWillClose?() fires, so any SwiftUI layout pass triggered by the
            // host app's close handler (e.g. nav-state reset → RootPanelView .id()
            // flip → PanelMainView remount → GR onAppear with settings-sized frame)
            // is suppressed here.
            if isClosing {
                mbkLog("PopoverController",
                       "applyContentSize -- closing in flight, SKIP WRITE+REANCHOR (\(clamped.width),\(clamped.height))")
                return
            }
            if widthChanged {
                // GUARDED (2): discard the entire call when the width narrows
                // mid-session and we are not in the opening sequence.
                //
                // WHY — the departing-view GR problem:
                // During main → settings → main navigation the settings view's
                // GeometryReader fires one last 480×551 report AFTER the main view
                // has remounted into the .id()-flipped RootPanelView tree.
                // isClosing=false, isOpening=false — no other guard catches it.
                //
                // Previous iteration wrote contentSize=480 here before returning,
                // reasoning the value "must not stay frozen". That write caused a
                // secondary failure: when the user later navigated to settings in
                // hidden mode, the settings GR fired 480×551 again, but contentSize
                // was already 480 (from the stale write), so the top-level dedup
                // guard (abs > 1) passed on height but Path 3's DIRECT FRAME wrote
                // against a chrome snapshot that was taken from a main-width window —
                // producing the correct numeric frame. Yet in practice the settings
                // GR never appeared in the hidden-mode log at all, meaning SwiftUI
                // did not re-fire the GR after the contentSize pollution.
                //
                // The correct fix is to SKIP ENTIRELY — no contentSize write, no
                // reanchor. contentSize stays at the authoritative main-view width
                // (642.5). When the user genuinely navigates to settings (visible or
                // hidden), the settings GR fires fresh against contentSize=642.5,
                // the dedup passes cleanly, and Path 2 or Path 3 writes the correct
                // 480×551 with no collision.
                if clamped.width < oldWidth - 1 && !isOpening {
                    mbkLog("PopoverController",
                           "applyContentSize -- width narrowed mid-session (\(oldWidth) → \(clamped.width)), SKIP entirely, stale departing-view GR discarded")
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
