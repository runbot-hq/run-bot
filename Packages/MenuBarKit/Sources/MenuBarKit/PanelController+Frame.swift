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
// ❌ NEVER set `hostingView.frame` by hand. The hosting view is pinned to the
//    window's content view with required constraints; the *window* resizes and
//    the hosting view follows. Assigning its frame directly was how the content
//    ended up bigger than the window, centred and clipped at both ends.
//
// LOGGING CONTRACT (the on-device diagnostic surface):
//   MEASURE  measured=(w,h) content=(w,h) cap=… reason=…
//   WRITE    content=(w,h) anchorX=… topY=… hidden=… frame=… arrowX=… clamped=…
//   SKIP     -- content unchanged / degenerate intrinsic size
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

        // A nil screen means the button window is entirely off-screen; a button
        // top above the screen top means the menu bar has slid away. `>` not `>=`:
        // equality is the normal flush resting position.
        let hidden = buttonScreen == nil || (buttonWindow?.frame.maxY ?? -1) > screen.frame.maxY

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
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// The current content height cap, recomputed from the live visible frame.
    /// - Returns: Maximum content height in points.
    func liveMaxContentHeight() -> CGFloat {
        MBKPanelGeometry.maxContentHeight(
            visibleFrame: liveVisibleFrame(),
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

    /// Measures the hosted content and applies the resulting frame.
    ///
    /// Called only through `MBKSizeCoalescer`, so at most once per runloop turn.
    ///
    /// The hosting view measures the *whole* bubble — the SwiftUI root adds the
    /// arrow inset itself — so the arrow strip is subtracted here to recover the
    /// content size that `MBKPanelGeometry` expects.
    func applyMeasuredSize() {
        guard let hostingView, let limits else { return }
        let measured = hostingView.intrinsicContentSize
        guard measured.width > 0, measured.height > 0 else {
            mbkLog("PanelController", "SKIP -- degenerate intrinsic size (\(measured.width),\(measured.height))")
            return
        }
        lastMeasuredSize = measured

        let cap = limits.maxContentHeight
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

        if isShown, let last = lastContentSize,
           abs(last.width - content.width) < 1, abs(last.height - content.height) < 1 {
            mbkLog("PanelController", "SKIP -- content unchanged (\(content.width),\(content.height))")
            return
        }
        lastContentSize = content
        applyFrame(content: content, reason: "WRITE")
    }

    /// Re-measures after a layout pass and schedules an apply if the size moved.
    ///
    /// The safety net behind `invalidateIntrinsicContentSize()`. A layout pass
    /// that produces the same measurement does nothing at all, so this costs one
    /// cached property read per pass in the steady state.
    /// - Parameter reason: Log token describing what triggered the re-measure.
    func scheduleIfMeasurementChanged(reason: String) {
        guard !isApplyingFrame, let hostingView, let coalescer else { return }
        let measured = hostingView.intrinsicContentSize
        guard measured.width > 0, measured.height > 0 else { return }
        if let last = lastMeasuredSize,
           abs(last.width - measured.width) < 1, abs(last.height - measured.height) < 1 {
            return
        }
        mbkLog(
            "PanelController",
            "MEASURE \(reason) -- measured=(\(measured.width),\(measured.height)) differs from applied, scheduling"
        )
        coalescer.schedule()
    }

    // MARK: - Apply

    /// Computes and applies the window frame, and feeds the arrow position to SwiftUI.
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

        isApplyingFrame = true
        if abs(limits.arrowCenterX - layout.arrowCenterX) >= 0.5 {
            limits.arrowCenterX = layout.arrowCenterX
        }
        panel.setFrame(layout.frame, display: true)
        // Resize the window, then let Auto Layout push the new bounds through the
        // pinned hosting view so SwiftUI re-proposes the real size on this turn.
        panel.contentView?.layoutSubtreeIfNeeded()
        // The window is fully clear, so the shadow is derived from the rendered
        // alpha of the glass bubble. It has to be recomputed for the new shape.
        panel.invalidateShadow()
        isApplyingFrame = false

        mbkLog(
            "PanelController",
            """
            \(reason) content=(\(content.width),\(content.height)) \
            anchorX=\(anchor.anchorX) topY=\(anchor.topY) hidden=\(anchor.menuBarHidden) \
            frame=\(layout.frame) arrowX=\(layout.arrowCenterX) clamped=\(layout.wasClamped)
            """
        )

        // The re-proposal above may have changed what the content wants (a
        // ScrollView that now fits, a wrapped label that now needs a second
        // line). Converge on the next turn rather than leaving it to chance.
        scheduleIfMeasurementChanged(reason: "post-apply")
    }

    /// Recomputes the height cap and re-applies the frame after a display change.
    func refreshForScreenChange() {
        guard let limits else { return }
        let cap = liveMaxContentHeight()
        if abs(cap - limits.maxContentHeight) >= 1 {
            limits.maxContentHeight = cap
            mbkLog("PanelController", "screen change -- maxContentHeight=\(cap)")
        }
        guard isShown else { return }
        lastContentSize = nil
        lastMeasuredSize = nil
        coalescer?.flush()
    }
}
