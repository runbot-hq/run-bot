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
            // is suppressed here. Writing a stale width to contentSize and calling
            // show() while the popover is tearing down poisons the next open's
            // geometry (main opens at settings width). The popover is about to
            // disappear; no contentSize write or reanchor is needed.
            if isClosing {
                mbkLog("PopoverController",
                       "applyContentSize -- closing in flight, SKIP WRITE+REANCHOR (\(clamped.width),\(clamped.height))")
                return
            }
            popover.contentSize = clamped
            if widthChanged {
                // GUARDED (2): suppress show() reanchor when the incoming width is
                // narrower than the current contentSize width.
                //
                // WHY: during main → settings → main navigation the departing settings
                // view's GeometryReader fires one last size report (480×551) AFTER the
                // main view has remounted into the .id()-flipped RootPanelView tree.
                // At this point isClosing=false and isOpening=false — no existing guard
                // catches it. The 480-wide report goes through and triggers a show()
                // reanchor; AppKit resizes the live window to settings dimensions.
                // When the menubar subsequently hides, hiddenChromeW/H is snapshotted
                // from that poisoned window, corrupting every DIRECT FRAME write for
                // the rest of the hidden session (root cause of the wrong-size-in-
                // hidden-mode bug observed after the #2280 fix landed).
                //
                // A width decrease mid-session (new < old by more than 1pt, which is
                // already guaranteed by the widthChanged guard above) while the popover
                // is fully open and not opening/closing is structurally only possible
                // from a departing view's final GR fire — the live view's width never
                // shrinks during normal in-session navigation (main only widens as more
                // runners/jobs load; settings is always narrower than main).
                //
                // Action: write contentSize (already done above — the value must not
                // stay frozen at the old width in case the arriving view happens to
                // match it) but skip show(). The arriving main-view GR fires
                // immediately after and performs the authoritative reanchor to the
                // correct width.
                if clamped.width < oldWidth - 1 && !isOpening {
                    mbkLog("PopoverController",
                           "applyContentSize -- width narrowed mid-session (\(oldWidth) → \(clamped.width)), WRITE only, stale departing-view GR suppressed")
                    return
                }
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
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE only, height-only change (\(clamped.width),\(clamped.height))")
            }
        }
    }
}
