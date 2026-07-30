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
        guard let button = statusItem?.button else {
            mbkLog("PanelController", "readAnchor -- NO BUTTON")
            return nil
        }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        guard let screen = buttonScreen ?? NSScreen.main else {
            mbkLog("PanelController", "readAnchor -- NO SCREEN")
            return nil
        }
        let visibleFrame = screen.visibleFrame

        let hidden = buttonScreen == nil
            || MBKPanelGeometry.isMenuBarHidden(screenFrame: screen.frame, visibleFrame: visibleFrame)

        let anchorX: CGFloat
        if let window = buttonWindow, window.frame.width > 0 {
            anchorX = window.frame.minX + button.frame.midX
            lastKnownAnchorX = anchorX
            // Normal path — no log needed
        } else if let cached = lastKnownAnchorX {
            anchorX = cached
            mbkLog("PanelController", "readAnchor -- CACHED fallback anchorX=\(anchorX)")
        } else {
            anchorX = visibleFrame.maxX - metrics.screenMargin
            mbkLog("PanelController", "readAnchor -- FALLBACK no cache anchorX=\(anchorX)")
        }

        let topY: CGFloat
        if hidden {
            topY = visibleFrame.maxY
        } else if let window = buttonWindow, window.frame.minY > 0 {
            topY = window.frame.minY
        } else {
            topY = visibleFrame.maxY
        }
        mbkLog("PanelController", "readAnchor -- anchorX=\(anchorX) topY=\(topY) hidden=\(hidden) buttonWindow=\(buttonWindow != nil) buttonScreen=\(buttonScreen != nil)")
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
        mbkLog("PanelController", "applyMeasuredSize -- measured=(\(measured.width),\(measured.height)) isShown=\(isShown) lastContentSize=\(lastContentSize.map { "(\($0.width),\($0.height))" } ?? "nil")")

        let anchor = readAnchor()
        let visibleFrame = anchor?.visibleFrame ?? liveVisibleFrame()
        let topY = anchor?.topY ?? visibleFrame.maxY
        let cap = MBKPanelGeometry.maxContentHeight(
            topY: topY,
            visibleFrame: visibleFrame,
            fraction: maxHeightFraction,
            metrics: metrics
        )
        let content = MBKPanelGeometry.clampContent(
            CGSize(width: measured.width, height: measured.height - metrics.arrowHeight),
            minWidth: 1,
            maxWidth: liveMaxContentWidth(),
            maxHeight: cap
        )
        mbkLog(
            "PanelController",
            "applyMeasuredSize CLAMPED -- content=(\(content.width),\(content.height)) cap=\(cap)"
        )

        mbkLog("PanelController", "applyMeasuredSize DEDUP -- last=\(lastContentSize.map { "(\($0.width),\($0.height))" } ?? "nil") new=(\(content.width),\(content.height))")
        if let last = lastContentSize,
           abs(last.width - content.width) < 1, abs(last.height - content.height) < 1 {
            mbkLog("PanelController", "SKIP -- content unchanged (\(content.width),\(content.height)) lastContentSize=\(lastContentSize.map { "(\($0.width),\($0.height))" } ?? "nil") SUPPRESSED")
            return
        }
        lastContentSize = content
        applyFrame(content: content, anchor: anchor, reason: "WRITE")
    }

    // MARK: - Apply

    func applyFrame(content: CGSize, anchor: MBKAnchorReading? = nil, reason: String) {
        mbkLog("PanelController", "applyFrame ENTER -- content=(\(content.width),\(content.height)) reason=\(reason)")
        guard let panel, let limits, hasOpenedOnce else { return }
        guard let anchor = anchor ?? readAnchor() else {
            mbkLog("PanelController", "\(reason) -- no anchor available, skipping frame")
            return
        }
        mbkLog("PanelController", "applyFrame ANCHOR -- anchorX=\(anchor.anchorX) topY=\(anchor.topY) hidden=\(anchor.menuBarHidden) visibleFrame=\(anchor.visibleFrame)")
        let layout = MBKPanelGeometry.layout(
            content: content,
            anchorX: anchor.anchorX,
            topY: anchor.topY,
            visibleFrame: anchor.visibleFrame,
            metrics: metrics
        )
        mbkLog("PanelController", "applyFrame LAYOUT -- layout.frame=\(layout.frame) arrowX=\(layout.arrowCenterX) wasClamped=\(layout.wasClamped)")

        mbkLog("PanelController", "applyFrame PRE-SET -- current panel.frame=\(panel.frame)")
        if abs(limits.arrowCenterX - layout.arrowCenterX) >= 0.5 {
            limits.arrowCenterX = layout.arrowCenterX
        }
        panel.setFrame(layout.frame, display: true)
        panel.invalidateShadow()
        mbkLog("PanelController", "applyFrame POST-SET -- panel.frame=\(panel.frame)")

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
        mbkLog("PanelController", "refreshForScreenChange -- cap=\(cap) currentMax=\(limits.maxContentHeight) isShown=\(isShown)")
        if abs(cap - limits.maxContentHeight) >= 1 {
            limits.maxContentHeight = cap
            mbkLog("PanelController", "refreshForScreenChange -- maxContentHeight updated to \(cap)")
        }
        guard isShown else { return }
        lastContentSize = nil
        let size = hostingController.preferredContentSize
        if size.width > 0, size.height > 0 {
            mbkLog("PanelController", "refreshForScreenChange -- re-applying preferredContentSize=(\(size.width),\(size.height))")
            applyMeasuredSize(size)
        } else {
            mbkLog("PanelController", "refreshForScreenChange -- no pcs yet, waiting for KVO")
        }
    }
}
