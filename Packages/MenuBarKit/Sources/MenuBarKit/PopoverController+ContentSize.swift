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
            // Path 3: hidden mode — NSPopover ignores setContentSize here.
            //
            // Chrome deltas and buttonMidX are snapshotted once per hidden session.
            // On a view switch (size delta > 20pt in either dimension vs the PREVIOUS
            // content size, not popover.contentSize which may be stale) the chrome
            // snapshot is invalidated so it re-fires against the new view's
            // window.frame. buttonMidX is preserved — the button hasn't moved.
            //
            // ❌ Do NOT write popover.contentSize before computing chrome deltas —
            // that makes window.frame stale relative to contentSize and breaks Y.
            // ❌ Do NOT re-snapshot on every call — window.frame is only valid at
            // the moment after the previous setFrame, not on every layout pass.
            // ❌ Do NOT use a hiddenWindowTop snapshot — it is taken from whichever
            // view fires first and will be wrong for subsequent views.
            // The Y formula window.frame.origin.y + (window.frame.height - newH)
            // is correct at (re-)snapshot time because window.frame is fresh.
            //
            // Y-FLOOR SAFETY:
            // A bad re-snapshot (stale window.frame after a prior setFrame) can
            // produce a negative chromeH, pushing newY above the visible screen
            // area (under the macOS notch island). After computing newY, we floor
            // it to visibleFrame.minY so the panel can never rise above the
            // menubar/notch regardless of snapshot timing.
            let prevW = hiddenChromeW.map { popover.contentSize.width } ?? clamped.width
            let prevH = hiddenChromeH.map { popover.contentSize.height } ?? clamped.height
            let viewSwitched = hiddenChromeW != nil && (
                abs(clamped.width  - prevW) > 20 ||
                abs(clamped.height - prevH) > 20
            )
            if viewSwitched {
                hiddenChromeW = nil
                hiddenChromeH = nil
                mbkLog("PopoverController",
                       "applyContentSize -- hidden view switch detected, invalidating chrome snapshot")
            }

            if hiddenChromeW == nil,
               let button = statusItem.button,
               let buttonWin = button.window {
                hiddenChromeW = window.frame.width  - popover.contentSize.width
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
            let newW = clamped.width  + chromeW
            let newH = clamped.height + chromeH
            // ❌ DO NOT use window.frame.origin.x as a fixed left edge here —
            // it was computed for a specific width and is wrong for any other width.
            // Always derive originX from btnMidX so main and settings (which have
            // different widths) both land centred under the status item.
            let newX = btnMidX - newW / 2
            // Anchor from current bottom edge upward — self-contained.
            // window.frame is valid here: either this is the initial snapshot call
            // (window.frame set by AppKit at show time) or the view-switch re-snapshot
            // (window.frame set by our previous setFrame for the prior view).
            let rawY = window.frame.origin.y + (window.frame.height - newH)
            // Y-FLOOR: clamp so the panel top never rises above the visible screen area.
            // A bad re-snapshot (negative chromeH) would push rawY above visibleFrame.minY
            // and place the window under the macOS notch island. ❌ DO NOT REMOVE.
            let visibleFloor = window.screen?.visibleFrame.minY ?? 0
            let newY = max(rawY, visibleFloor)
            if newY != rawY {
                mbkLog("PopoverController",
                       "applyContentSize -- hidden Y floored rawY=\(rawY) → \(newY) visibleFloor=\(visibleFloor)")
            }
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
