// PanelController+Frame.swift
// MenuBarKit
//
// The one and only frame pipeline.
//
// LOGGING CONTRACT:
//   GEOMETRY  naturalSize=(w,h) — onGeometryChange fired with this size
//   MEASURE   naturalSize=(w,h) content=(w,h) cap=…  — after clamping
//   WRITE     content=(w,h) anchorX=… topY=… frame=… arrowX=… clamped=…
//   SKIP      -- reason
//
// ❌ NEVER call panel.setFrame anywhere else.
// ❌ NEVER set hostingController.view.frame by hand.

import AppKit

struct MBKAnchorReading {
    let anchorX: CGFloat
    let topY: CGFloat
    let visibleFrame: CGRect
    let menuBarHidden: Bool
}

extension MBKPanelController {

    // MARK: - Anchor

    func readAnchor() -> MBKAnchorReading? {
        guard let button = statusItem?.button else {
            mbkLog("PanelController", "readAnchor -- no status button")
            return nil
        }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        guard let screen = buttonScreen ?? NSScreen.main else {
            mbkLog("PanelController", "readAnchor -- no screen")
            return nil
        }
        let visibleFrame = screen.visibleFrame

        let hidden = buttonScreen == nil
            || MBKPanelGeometry.isMenuBarHidden(screenFrame: screen.frame, visibleFrame: visibleFrame)

        let anchorX: CGFloat
        if let window = buttonWindow, window.frame.width > 0 {
            anchorX = window.frame.minX + button.frame.midX
            lastKnownAnchorX = anchorX
        } else if let cached = lastKnownAnchorX {
            anchorX = cached
            mbkLog("PanelController", "readAnchor -- using cached anchorX=\(cached)")
        } else {
            anchorX = visibleFrame.maxX - metrics.screenMargin
            mbkLog("PanelController", "readAnchor -- fallback anchorX=\(anchorX)")
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

    /// Entry point from onGeometryChange. `measured` is the inner VStack's natural size
    /// (content + arrowHeight padding already included via .padding(.top, arrowHeight)).
    func applyMeasuredSize(_ measured: CGSize) {
        mbkLog("PanelController", "applyMeasuredSize -- entry measured=(\(measured.width),\(measured.height)) isShown=\(isShown) hasOpenedOnce=\(hasOpenedOnce) isApplyingFrame=\(isApplyingFrame)")

        guard !isApplyingFrame else {
            mbkLog("PanelController", "SKIP -- reentrant call during applyFrame")
            return
        }
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
            mbkLog("PanelController", "SKIP -- degenerate size (\(measured.width),\(measured.height))")
            return
        }

        lastMeasuredSize = measured

        let cap = liveMaxContentHeight()
        // measured already includes arrowHeight via .padding(.top) in the inner VStack.
        // Subtract arrowHeight so clampContent operates on pure content height.
        let contentHeight = measured.height - metrics.arrowHeight
        let content = MBKPanelGeometry.clampContent(
            CGSize(width: measured.width, height: contentHeight),
            minWidth: 1,
            maxWidth: liveMaxContentWidth(),
            maxHeight: cap
        )
        mbkLog(
            "PanelController",
            "MEASURE naturalSize=(\(measured.width),\(measured.height)) contentHeight=\(contentHeight) content=(\(content.width),\(content.height)) cap=\(cap)"
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
            mbkLog("PanelController", "frameWritesAllowed -- false, not opened yet")
        }
        return false
    }

    func applyFrame(content: CGSize, reason: String) {
        guard let panel, let limits, frameWritesAllowed() else {
            mbkLog("PanelController", "applyFrame SKIP -- panel=\(panel != nil) limits=\(limits != nil) frameWritesAllowed=\(frameWritesAllowed())")
            return
        }
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
        guard isShown else { return }
        mbkLog("PanelController", "refreshForScreenChange -- forcing layout pass")
        lastContentSize = nil
        lastMeasuredSize = nil
        hostingController.view.layoutSubtreeIfNeeded()
    }
}
