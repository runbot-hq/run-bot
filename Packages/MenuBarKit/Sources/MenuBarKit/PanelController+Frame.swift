// PanelController+Frame.swift
// MenuBarKit
//
// The one and only frame pipeline.
//
// Every frame the panel ever gets comes from `applyFrame(content:reason:)`.
// There is no second write path, no chrome-delta snapshot, and no per-session
// positional state — the anchor is read live from the status button and the
// screen each time. That is what makes the hidden-menu-bar case fall out for
// free instead of needing a post-show correction.
//
// ❌ NEVER call `panel.setFrame` or `setFrameOrigin` anywhere else.
// ❌ NEVER set `hostingView.frame` by hand. The hosting view is pinned
//    to the window's content view with required constraints; the *window* resizes
//    and the hosting view follows.
//
// LOGGING CONTRACT (the on-device diagnostic surface):
//   MEASURE  measured=(w,h) content=(w,h) cap=… reason=…
//   WRITE    content=(w,h) anchorX=… topY=… hidden=… frame=… arrowX=… clamped=…
//   SKIP     -- content unchanged / degenerate intrinsic size / not shown yet
// Every measurement the pipeline saw and every frame it applied has a line.

import AppKit

/// Live anchor reading: where the panel must attach for one frame computation.
struct MBKAnchorReading {

    /// Status-button centre X in screen coordinates.
    let anchorX: CGFloat

    /// Screen Y that the top edge of the panel should touch.
    let topY: CGFloat

    /// Visible frame of the screen hosting the status item.
    let visibleFrame: CGRect

    /// `true` when the auto-hide menu bar is currently slid off-screen.
    let menuBarHidden: Bool
}

/// Anchor reading and frame application for `MBKPanelController`.
extension MBKPanelController {

    // MARK: - Anchor

    /// Reads the live anchor from the status button and its screen.
    ///
    /// `anchorX` is derived as `buttonWindow.frame.minX + button.frame.midX`
    /// rather than from the status-bar window's midX, because that expression
    /// stays correct while the auto-hide menu bar is hidden — the status window
    /// slides above the screen top but keeps its X.
    ///
    /// - Returns: The reading, or `nil` if there is no status button or screen yet.
    func readAnchor() -> MBKAnchorReading? {
        guard let button = statusItem?.button else { return nil }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        guard let screen = buttonScreen ?? NSScreen.main else { return nil }
        let visibleFrame = screen.visibleFrame

        // The menu-bar state comes from the screen, not from the status window.
        // The old heuristic compared `buttonWindow.frame.maxY` against
        // `screen.frame.maxY`, which differ by about a point depending on the
        // app's activation state — so `hidden` flapped between consecutive
        // writes with the menu bar plainly visible. The screen's own visible
        // frame is unambiguous and moves by a whole menu-bar height, far outside
        // the tolerance. A nil button screen still means "off-screen entirely".
        let hidden = buttonScreen == nil
            || MBKPanelGeometry.isMenuBarHidden(screenFrame: screen.frame, visibleFrame: visibleFrame)

        let anchorX: CGFloat
        if let window = buttonWindow, window.frame.width > 0 {
            anchorX = window.frame.minX + button.frame.midX
            lastKnownAnchorX = anchorX
        } else if let cached = lastKnownAnchorX {
            anchorX = cached
        } else {
            anchorX = visibleFrame.maxX - metrics.screenMargin
        }

        let topY = hidden ? visibleFrame.maxY : (buttonWindow?.frame.minY ?? visibleFrame.maxY)
        return MBKAnchorReading(
            anchorX: anchorX,
            topY: topY,
            visibleFrame: visibleFrame,
            menuBarHidden: hidden
        )
    }

    /// The visible frame the panel is currently anchored to.
    /// - Returns: The status item's screen's visible frame, with sane fallbacks.
    private func liveVisibleFrame() -> CGRect {
        statusItem?.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            // HEADLESS FALLBACK — only reachable when NSScreen.main is nil (e.g. CI with
            // no display attached). Never reached in production. Tests that call
            // liveVisibleFrame() indirectly in a headless environment will silently use
            // this rect — pure-math geometry tests pass their own visibleFrame directly
            // and are not affected, but future indirect callers should be aware.
            // A sane non-zero rect is used rather than CGRect.zero because zero produces a
            // degenerate maxContentHeight of 0, which would suppress all frame writes if
            // somehow reached while the panel is visible.
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The current content height cap, recomputed from the live anchor and visible frame.
    ///
    /// `topY` is read from the live anchor so the cap uses the drawable space below the
    /// menu bar rather than the full visible-frame height. Falls back to `visibleFrame.maxY`
    /// when no anchor is available (e.g. headless CI or pre-setup call).
    /// - Returns: Maximum content height in points.
    func liveMaxContentHeight() -> CGFloat {
        let vf = liveVisibleFrame()
        let topY = readAnchor()?.topY ?? vf.maxY
        return MBKPanelGeometry.maxContentHeight(
            topY: topY,
            visibleFrame: vf,
            fraction: maxHeightFraction,
            metrics: metrics
        )
    }

    /// The only width limit MenuBarKit imposes: the panel never grows wider than
    /// the screen it is anchored to. Adopter-specific widths belong in the
    /// adopter's own views — see the note on `MBKPanelController.init`.
    /// - Returns: Maximum content width in points.
    func liveMaxContentWidth() -> CGFloat {
        MBKPanelGeometry.maxContentWidth(visibleFrame: liveVisibleFrame(), metrics: metrics)
    }

    // MARK: - Measure

    /// Receives the settled size from the `onGeometryChange` callback and
    /// applies the resulting frame.
    ///
    /// `onGeometryChange` fires once per settled SwiftUI layout pass — no burst,
    /// no coalescer needed. The hosting view measures the *whole* bubble — the
    /// SwiftUI root adds the arrow inset itself — so the arrow strip is
    /// subtracted here to recover the content size that `MBKPanelGeometry`
    /// expects.
    /// - Parameter measured: The new size from `onGeometryChange`.
    func applyMeasuredSize(_ measured: CGSize) {
        // Guard against post-close re-entry: the onGeometryChange callback can fire
        // on the next actor turn after teardown. Without this guard it would seed
        // lastContentSize with a stale size, causing the next open to hit the
        // "SKIP -- content unchanged" dedupe and show the panel at the wrong size.
        guard isShown else {
            mbkLog("PanelController", "SKIP -- panel not shown, dropping post-close measurement")
            return
        }
        guard limits != nil else { return }
        guard measured.width > 0, measured.height > 0 else {
            mbkLog("PanelController", "SKIP -- degenerate intrinsicContentSize (\(measured.width),\(measured.height))")
            return
        }

        let cap = maxContentHeight
        let content = MBKPanelGeometry.clampContent(
            CGSize(width: measured.width, height: measured.height - metrics.arrowHeight),
            minWidth: 1,
            maxWidth: liveMaxContentWidth(),
            maxHeight: cap
        )
        mbkLog(
            "PanelController",
            """
            MEASURE measured=(\(measured.width),\(measured.height)) \
            content=(\(content.width),\(content.height)) cap=\(cap) shown=\(isShown)
            """
        )

        if let last = lastContentSize,
           abs(last.width - content.width) < 1, abs(last.height - content.height) < 1 {
            mbkLog("PanelController", "SKIP -- content unchanged (\(content.width),\(content.height))")
            return
        }
        lastContentSize = content
        applyFrame(content: content, reason: "WRITE")
    }

    // MARK: - Apply

    /// Computes and applies the window frame, and feeds the arrow position to the chrome.
    /// - Parameters:
    ///   - content: Clamped content size, excluding the arrow strip.
    ///   - reason: Log token describing the caller.
    func applyFrame(content: CGSize, reason: String) {
        guard let panel, let limits else { return }
        guard let anchor = readAnchor() else {
            mbkLog("PanelController", "\(reason) -- no anchor available, skipping frame")
            return
        }
        let layout = MBKPanelGeometry.layout(
            content: content,
            anchorX: anchor.anchorX,
            topY: anchor.topY,
            visibleFrame: anchor.visibleFrame,
            metrics: metrics
        )

        if abs(limits.arrowCenterX - layout.arrowCenterX) >= 0.5 {
            limits.arrowCenterX = layout.arrowCenterX
        }
        panel.setFrame(layout.frame, display: true)
        // ❌ NO layoutSubtreeIfNeeded here. Forcing a synchronous layout pass reads
        // the hosting view's stale intrinsicContentSize (SwiftUI hasn't settled yet),
        // which causes the hosting view to collapse to a degenerate height. This
        // degenerate height is then proposed to SwiftUI, which fires onGeometryChange
        // with a tiny size, which triggers another applyFrame → infinite loop.
        // The window resize with display: true already schedules a natural layout
        // pass on the next runloop turn, which is when SwiftUI has settled.
        // The shadow is derived from the rendered alpha of the glass bubble, which
        // is correct after the natural layout pass.
        panel.invalidateShadow()

        mbkLog(
            "PanelController",
            """
            \(reason) content=(\(content.width),\(content.height)) \
            anchorX=\(anchor.anchorX) topY=\(anchor.topY) hidden=\(anchor.menuBarHidden) \
            frame=\(layout.frame) arrowX=\(layout.arrowCenterX) clamped=\(layout.wasClamped)
            """
        )
    }

    /// Recomputes the height cap and re-applies the frame after a display change.
    func refreshForScreenChange() {
        guard limits != nil else { return }
        let cap = liveMaxContentHeight()
        if abs(cap - maxContentHeight) >= 1 {
            maxContentHeight = cap
            mbkLog("PanelController", "screen change -- maxContentHeight=\(cap)")
            // ❌ DO NOT rebuild hostingController.rootView here.
            //    MBKPanelContentView has no cap parameter since c80879c — there
            //    is nothing to propagate into the view. The rebuild was only ever
            //    needed when the view held the cap. Now it is a pure no-op that
            //    costs a full SwiftUI layout pass and discards any settled
            //    in-flight layout state. The updated cap is stored in
            //    self.maxContentHeight and will be read by applyMeasuredSize
            //    when onGeometryChange fires on the next layout pass.
        }
        guard isShown else { return }
        lastContentSize = nil
        // Schedule a natural layout pass. onGeometryChange will fire with the
        // correct natural size on the next runloop turn and call applyMeasuredSize.
        // ❌ DO NOT read fittingSize here — same race as invalidateContentSize:
        //    AppKit proposes the current window height to SwiftUI before it settles,
        //    so fittingSize reflects the window size, not the content’s natural size.
        hostingController.view.invalidateIntrinsicContentSize()
    }
}
