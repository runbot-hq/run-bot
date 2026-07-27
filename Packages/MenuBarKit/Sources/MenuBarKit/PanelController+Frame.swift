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

    /// The current content height cap, recomputed from the live visible frame.
    /// - Returns: Maximum content height in points.
    func liveMaxContentHeight() -> CGFloat {
        let visibleFrame = statusItem?.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return MBKPanelGeometry.maxContentHeight(
            visibleFrame: visibleFrame,
            fraction: maxHeightFraction,
            metrics: metrics
        )
    }

    // MARK: - Apply

    /// Measures the hosted content and applies the resulting frame.
    ///
    /// Called only through `MBKSizeCoalescer`, so at most once per runloop turn.
    func applyMeasuredSize() {
        guard let hostingView, let limits else { return }
        let intrinsic = hostingView.intrinsicContentSize
        guard intrinsic.width > 0, intrinsic.height > 0 else {
            mbkLog("PanelController", "SKIP -- degenerate intrinsic size (\(intrinsic.width),\(intrinsic.height))")
            return
        }
        let content = MBKPanelGeometry.clampContent(
            intrinsic,
            minWidth: minWidth,
            maxWidth: maxWidth,
            maxHeight: limits.maxContentHeight
        )

        if isShown, let last = lastContentSize,
           abs(last.width - content.width) < 1, abs(last.height - content.height) < 1 {
            mbkLog("PanelController", "SKIP -- content unchanged (\(content.width),\(content.height))")
            return
        }
        lastContentSize = content
        applyFrame(content: content, reason: "WRITE")
    }

    /// Computes and applies the window frame, the hosting-view frame, and the mask.
    /// - Parameters:
    ///   - content: Clamped content size, excluding chrome.
    ///   - reason: Log token describing the caller.
    func applyFrame(content: CGSize, reason: String) {
        guard let panel, let effectView, let hostingView else { return }
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
        panel.setFrame(layout.frame, display: true)
        effectView.maskImage = MBKPanelMask.image(
            size: layout.frame.size,
            arrowCenterX: layout.arrowCenterX,
            metrics: metrics,
            scale: panel.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        )
        hostingView.frame = CGRect(
            x: 0,
            y: 0,
            width: layout.frame.width,
            height: max(layout.frame.height - metrics.arrowHeight, 0)
        )
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
        guard let limits else { return }
        let cap = liveMaxContentHeight()
        if abs(cap - limits.maxContentHeight) >= 1 {
            limits.maxContentHeight = cap
            mbkLog("PanelController", "screen change -- maxContentHeight=\(cap)")
        }
        guard isShown else { return }
        lastContentSize = nil
        coalescer?.flush()
    }
}
