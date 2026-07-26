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
    /// hidden — `NSPopover.contentSize` is ignored by AppKit for window positioning,
    /// so drive `window.setFrame` directly using chrome deltas and fixed top-Y snapshotted
    /// once in `popoverWillShow`.
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
            // Always write contentSize, even when the menubar is hidden.
            // Writing contentSize while closed is safe regardless of menubar state —
            // AppKit does not act on it until the next show(). The earlier guard here
            // was intended to prevent bad-X positioning, but that risk applies only to
            // show()/reanchor calls, which Path 1 never makes. Skipping the write left
            // popover.contentSize stale (settings-view size) after a hidden-close, so
            // the next open briefly showed the main view at the settings size. See #2279.
            //
            // GUARDED: skip while the opening sequence is in flight (isOpening == true).
            // Between openPopover() calling popover.show() and the onDidShow Task
            // lowering isOpening, SwiftUI layout passes fire Path 1 with a stale
            // width from the previous session. Writing that stale value here makes
            // the popover briefly visible at the wrong size before onDidShow issues
            // the authoritative WRITE+REANCHOR. Suppressing the write is safe because
            // the correct geometry is committed by that WRITE+REANCHOR call anyway.
            if isOpening {
                mbkLog("PopoverController",
                       "applyContentSize -- not shown, opening in flight, SKIP WRITE (\(clamped.width),\(clamped.height))")
                return
            }
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        let oldWidth = popover.contentSize.width
        let widthChanged = abs(clamped.width - oldWidth) > 1

        if isMenuBarHidden {
            // Path 3: hidden mode — AppKit ignores NSPopover.contentSize for window
            // positioning, but SwiftUI's hosting controller still reads it for layout.
            //
            // Chrome deltas (hiddenChromeW/H), hiddenButtonMidX, and hiddenWindowTopY
            // are snapshotted ONCE in popoverWillShow against AppKit's freshly-
            // positioned stub window. They are constant for the entire session:
            //   - Chrome never changes between views (same NSPopover window).
            //   - buttonMidX never changes (button doesn't move).
            //   - windowTopY is the fixed TOP edge: the panel top stays pinned under
            //     the button; the panel grows downward as content height increases.
            //     Never recompute from window.frame — that drifts across setFrame calls.
            //
            // ❌ NEVER re-snapshot here. window.frame at this point is whatever WE
            //    last wrote via setFrame, not AppKit's frame.
            // ❌ NEVER invalidate hiddenChromeW/H/windowTopY mid-session.
            guard let chromeW = hiddenChromeW,
                  let chromeH = hiddenChromeH,
                  let btnMidX = hiddenButtonMidX,
                  let topY    = hiddenWindowTopY else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no chrome snapshot yet, SKIP (\(clamped.width),\(clamped.height))")
                return
            }
            // HIDDEN-MODE ARROW RE-ANCHOR (one-shot, first Path 3 call only):
            // When the popover opened in visible mode and the menubar subsequently
            // hid, AppKit's arrow placement was computed for the visible-mode window
            // position. Path 3's setFrame moves the window without AppKit's popover
            // positioning logic, so the baked-in arrow offset may no longer align
            // with the window edge after the frame shift — causing the arrow to
            // appear clipped or displaced.
            //
            // Issuing show() here forces AppKit to recompute arrow placement for the
            // current button/window geometry before we write the authoritative frame.
            // After this single re-anchor, hiddenModeAnchored = true suppresses
            // subsequent show() calls in Path 3 for the rest of the session.
            //
            // hiddenModeAnchored is already true when the popover opened while the
            // menubar was already hidden (set in popoverWillShow) — in that case
            // openPopover()'s own show() already anchored the arrow correctly and
            // this block is skipped entirely.
            //
            // NOTE: show() re-triggers popoverWillShow. The hiddenChromeW == nil
            // snapshot guard in popoverWillShow skips re-snapshotting on this call
            // (hiddenChromeW is already set). isShownSentinel = true is idempotent.
            // ❌ DO NOT remove this block or merge it with the Path 2 re-anchor logic —
            //    Path 2 never fires in hidden mode; this is the only re-anchor path
            //    for the visible→hidden mid-session transition.
            if !hiddenModeAnchored,
               let button = statusItem.button,
               let rect = positioningRect(for: button) {
                hiddenModeAnchored = true
                popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
                mbkLog("PopoverController",
                       "applyContentSize -- hidden mode, one-shot arrow re-anchor show() (\(clamped.width),\(clamped.height))")
            }
            // Write contentSize so SwiftUI's hosting controller lays out at the
            // correct size. AppKit ignores this for window positioning in hidden mode.
            popover.contentSize = clamped
            let newW = clamped.width  + chromeW
            let newH = clamped.height + chromeH
            // ❌ DO NOT use window.frame.origin.x — it was computed for a specific
            // width and is wrong for any other width. Always derive X from btnMidX.
            let newX = btnMidX - newW / 2
            // Derive bottom-left origin Y by subtracting the new frame height from
            // the fixed top edge. This pins the TOP of the panel just below the button
            // and grows the panel downward as content grows — correct macOS behaviour.
            // Using topY directly as origin.y would pin the BOTTOM edge and push the
            // top off-screen as the panel grows. ❌ NEVER use topY as origin.y.
            let newY = topY - newH
            // Y-FLOOR: last-resort safety clamp so the panel never rises above the
            // visible screen area under any edge case (e.g. external display removed
            // mid-session, Dock moved to a different edge).
            //
            // visibleFrame.minY on macOS is typically 0 (Dock at bottom) or the Dock
            // height (Dock at bottom, not auto-hiding). The ?? 0 fallback for a nil
            // screen is the most conservative safe value — it prevents the panel from
            // going off the top of a screen we cannot measure. This floor fires only
            // when newY is genuinely below visibleFloor; under normal operation
            // newY correctly tracks the panel bottom edge.
            // ❌ DO NOT REMOVE — this is a last-resort guard, not dead code.
            let visibleFloor = window.screen?.visibleFrame.minY ?? 0
            let clampedY = max(newY, visibleFloor)
            if clampedY != newY {
                mbkLog("PopoverController",
                       "applyContentSize -- hidden Y floored newY=\(newY) \u{2192} \(clampedY) visibleFloor=\(visibleFloor)")
            }
            let newFrame = NSRect(x: newX, y: clampedY, width: newW, height: newH)
            window.setFrame(newFrame, display: true)
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, DIRECT FRAME (\(clamped.width),\(clamped.height)) btnMidX=\(btnMidX) topY=\(topY) frame=\(newFrame)")
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
            // GUARDED: skip the show() reanchor while the opening sequence is in
            // flight (isOpening == true). The onDidShow Task issues the first
            // authoritative WRITE+REANCHOR which already positions the window
            // correctly; a second show() call before isOpening is cleared causes
            // the popover window to reposition and produces the one-time header
            // jump visible on first row tap after open.
            popover.contentSize = clamped
            if widthChanged {
                guard let button = statusItem.button,
                      let rect = positioningRect(for: button) else {
                    mbkLog("PopoverController",
                           "applyContentSize -- WRITE only, button unavailable for re-anchor (\(clamped.width),\(clamped.height))")
                    return
                }
                if isOpening {
                    mbkLog("PopoverController",
                           "applyContentSize -- WRITE only, opening in flight, skip reanchor (\(clamped.width),\(clamped.height))")
                    return
                }
                if let anchorX = buttonScreenMidX { lastKnownAnchorX = anchorX }
                popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE+REANCHOR via show() (\(clamped.width),\(clamped.height))")
            } else {
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE only, height-only change (\(clamped.width),\(clamped.height))")
            }
        }
    }
}
