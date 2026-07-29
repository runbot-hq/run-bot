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
// ❌ NEVER set `hostingController.view.frame` by hand. The hosting view is
//    pinned to the window's content view with required constraints; the *window*
//    resizes and the hosting view follows. Assigning its frame directly was how
//    the content ended up bigger than the window, centred and clipped at both ends.
//
// LOGGING CONTRACT (the on-device diagnostic surface):
//   MEASURE  measured=(w,h) content=(w,h) cap=… reason=…
//   WRITE    content=(w,h) anchorX=… topY=… hidden=… frame=… arrowX=… clamped=…
//   SKIP     -- content unchanged / degenerate / not shown yet
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

    func readAnchor() -> MBKAnchorReading? {
        guard let button = statusItem?.button else { return nil }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        guard let screen = buttonScreen ?? NSScreen.main else { return nil }
        let visibleFrame = screen.visibleFrame

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

    private func liveVisibleFrame() -> CGRect {
        statusItem?.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    func liveMaxContentHeight() -> CGFloat {
        MBKPanelGeometry.maxContentHeight(
            visibleFrame: liveVisibleFrame(),
            fraction: maxHeightFraction,
            metrics: metrics
        )
    }

    func liveMaxContentWidth() -> CGFloat {
        MBKPanelGeometry.maxContentWidth(visibleFrame: liveVisibleFrame(), metrics: metrics)
    }

    // MARK: - Measure

    func applyMeasuredSize(_ measured: CGSize) {
        guard isShown else {
            mbkLog("PanelController", "SKIP -- panel not shown, dropping post-close measurement")
            return
        }
        guard limits != nil, frameWritesAllowed() else { return }
        guard measured.width > 0, measured.height > 0 else {
            mbkLog("PanelController", "SKIP -- degenerate preferredContentSize (\(measured.width),\(measured.height))")
            return
        }
        lastMeasuredSize = measured

        let cap = liveMaxContentHeight()
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

    // MARK: - Apply

    func frameWritesAllowed() -> Bool {
        if hasOpenedOnce { return true }
        if !didLogPreOpenSkip {
            didLogPreOpenSkip = true
            mbkLog("PanelController", "SKIP -- not shown yet")
        }
        return false
    }

    func applyFrame(content: CGSize, reason: String) {
        guard let panel, frameWritesAllowed() else { return }
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
        if let limits, abs(limits.arrowCenterX - layout.arrowCenterX) >= 0.5 {
            limits.arrowCenterX = layout.arrowCenterX
        }
        panel.setFrame(layout.frame, display: true)
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
    }

    func refreshForScreenChange() {
        guard isShown else { return }
        lastContentSize = nil
        lastMeasuredSize = nil
        mbkLog("PanelController", "screen change -- will re-measure on next KVO fire")
    }
}
