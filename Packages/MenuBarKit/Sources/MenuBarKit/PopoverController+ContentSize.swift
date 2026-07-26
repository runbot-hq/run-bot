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
            // Path 3: hidden mode — NSPopover ignores setContentSize for window sizing,
            // but SwiftUI's hosting controller still reads contentSize to constrain its
            // layout. Write contentSize first so SwiftUI lays out at the correct width,
            // then drive window.setFrame directly using snapshotted chrome deltas.
            //
            // Chrome deltas, button X, and window top edge are snapshotted once in
            // popoverWillShow per session. Never invalidated or recalculated.
            //
            // KNOWN LIMITATION — mid-session menubar hide:
            // hiddenWindowY (and all chrome snapshot values) are captured in
            // popoverWillShow, which fires before any of our setFrame calls.
            // If the popover is already open in visible-menubar mode and the user
            // enables auto-hide mid-session, isMenuBarHidden will flip true and
            // Path 3 will activate using a hiddenWindowY that was snapshotted from
            // a window position that may have since been moved by Path 2 reanchors.
            // This is accepted risk: fixing it properly would require observing
            // NSApplicationDidChangeScreenParametersNotification and re-snapshotting
            // on menubar-hide transitions, which adds complexity disproportionate to
            // the frequency of the scenario. In practice, the popover is almost always
            // closed before the user toggles auto-hide.
            //
            // ❌ NEVER recalculate Y from window.frame — it moves on every setFrame call.
            //    hiddenWindowY is the snapshotted TOP EDGE (maxY), held constant for the
            //    session. origin.y is derived per-call as hiddenWindowY - windowHeight so
            //    the top of the popover stays pinned just below the status bar regardless
            //    of how tall the content grows.
            // ❌ Do NOT write popover.contentSize before computing the snapshot —
            //    the delta math reads both window.frame and popover.contentSize and
            //    they must be consistent (both reflecting the same prior state).
            guard let chromeW = hiddenChromeW,
                  let chromeH = hiddenChromeH,
                  let btnMidX = hiddenButtonMidX,
                  let topEdge = hiddenWindowY else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no chrome snapshot yet, SKIP (\(clamped.width),\(clamped.height))")
                return
            }
            // Write contentSize so SwiftUI constrains its layout to the correct size.
            // AppKit ignores this for window positioning in hidden mode, but the
            // hosting controller uses it for view layout.
            popover.contentSize = clamped
            let newW = clamped.width  + chromeW
            let newH = clamped.height + chromeH
            // ❌ DO NOT use window.frame.origin.x — it was computed for a specific
            // width and is wrong for any other width. Derive X from btnMidX always.
            let newX = btnMidX - newW / 2
            // Y is derived from the snapshotted top edge so the top of the popover
            // stays pinned just below the status bar on every height change.
            // origin.y = topEdge - windowHeight (AppKit uses bottom-left origin).
            let newY = topEdge - newH
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
