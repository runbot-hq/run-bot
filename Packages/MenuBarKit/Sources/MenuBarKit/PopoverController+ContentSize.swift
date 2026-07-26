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
            // Re-snapshot chrome deltas and buttonMidX on every call.
            // The one-shot (hiddenChromeW == nil) guard caused stale chrome metrics
            // when the view switched (e.g. main → settings) while hidden: the
            // snapshot taken from the main view's frame was used to size the settings
            // window, producing settings stuck at main-view dimensions. Chrome deltas
            // (window.frame − popover.contentSize) are a constant of the window
            // decoration — re-computing on every call is harmless and always correct.
            guard let button = statusItem.button,
                  let buttonWin = button.window else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no button/window, SKIP (\(clamped.width),\(clamped.height))")
                return
            }
            let chromeW = window.frame.width - popover.contentSize.width
            let chromeH = window.frame.height - popover.contentSize.height
            let btnMidX = buttonWin.frame.minX + button.frame.midX
            // Keep stored properties in sync so popoverDidClose reset remains a clean no-op.
            hiddenChromeW = chromeW
            hiddenChromeH = chromeH
            hiddenButtonMidX = btnMidX
            let newW = clamped.width + chromeW
            let newH = clamped.height + chromeH
            // ❌ DO NOT use window.frame.origin.x as a fixed left edge here —
            // it was computed for a specific width and is wrong for any other width.
            // Always derive originX from btnMidX so main and settings (which have
            // different widths) both land centred under the status item.
            let newX = btnMidX - newW / 2
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
