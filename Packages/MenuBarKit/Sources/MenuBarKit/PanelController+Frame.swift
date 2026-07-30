// PanelController+Frame.swift
// MenuBarKit
//
// The one and only frame pipeline.
//
// Every frame the panel ever gets comes from `applyFrame(content:reason:)`.
// There is no second write path, no chrome-delta snapshot, and no per-session
// positional state — the anchor is read live from the status button and the
// screen each time.
//
// ❌ NEVER call `panel.setFrame` or `setFrameOrigin` anywhere else.
// ❌ NEVER set `hostingController.view.frame` by hand.
//
// LOGGING CONTRACT:
//   KVO      preferredContentSize fired with (w,h)
//   MEASURE  measured=(w,h) content=(w,h) cap=…
//   WRITE    content=(w,h) anchorX=… topY=… hidden=… frame=… arrowX=… clamped=…
//   SKIP     -- reason

import AppKit

/// Live anchor reading: where the panel must attach for one frame computation.
struct MBKAnchorReading {
    let anchorX: CGFloat
    let topY: CGFloat
    let visibleFrame: CGRect
    let menuBarHidden: Bool
}

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
        let visible = liveVisibleFrame()
        let topY = readAnchor()?.topY ?? visible.maxY
        return MBKPanelGeometry.maxContentHeight(
            topY: topY,
            visibleFrame: visible,
            fraction: maxHeightFraction,
            metrics: metrics
        )
    }

    func liveMaxContentWidth() -> CGFloat {
        MBKPanelGeometry.maxContentWidth(visibleFrame: liveVisibleFrame(), metrics: metrics)
    }

    // MARK: - Measure

    /// Entry point from KVO on preferredContentSize and from invalidateContentSize().
    /// `measured` is the size AppKit read from SwiftUI under an unspecified proposal.
    /// It includes arrowHeight because MBKPanelContentView adds .padding(.top, arrowHeight).
    func applyMeasuredSize(_ measured: CGSize) {
        guard hasOpenedOnce else {
            mbkLog("PanelController", "SKIP -- not shown yet, storing for first open")
            lastMeasuredSize = measured
            return
        }
        guard isShown else {
            mbkLog("PanelController", "SKIP -- panel not shown, dropping post-close measurement")
            return
        }
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
            "MEASURE measured=(\(measured.width),\(measured.height)) content=(\(content.width),\(content.height)) cap=\(cap)"
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

    func frameWritesAllowed() -> Bool {
        if hasOpenedOnce { return true }
        if !didLogPreOpenSkip {
            didLogPreOpenSkip = true
            mbkLog("PanelController", "SKIP -- not opened yet")
        }
        return false
    }

    func applyFrame(content: CGSize, reason: String) {
        guard let panel, let limits, frameWritesAllowed() else { return }
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
        guard let limits else { return }
        let cap = liveMaxContentHeight()
        if abs(cap - limits.maxContentHeight) >= 1 {
            limits.maxContentHeight = cap
            mbkLog("PanelController", "refreshForScreenChange -- maxContentHeight updated to \(cap)")
        }
        guard isShown else { return }
        lastContentSize = nil
        lastMeasuredSize = nil
        let size = hostingController.preferredContentSize
        if size.width > 0, size.height > 0 {
            mbkLog("PanelController", "refreshForScreenChange -- re-applying preferredContentSize=(\(size.width),\(size.height))")
            applyMeasuredSize(size)
        } else {
            mbkLog("PanelController", "refreshForScreenChange -- no pcs yet, waiting for KVO")
        }
    }
}
