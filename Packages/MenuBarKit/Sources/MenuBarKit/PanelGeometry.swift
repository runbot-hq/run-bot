// PanelGeometry.swift
// MenuBarKit
//
// PURE MATH — no AppKit, no state, no logging side effects.
//
// Everything in this file is a value type or a static function over value
// types. That is deliberate: the frame math is the part of the panel that was
// historically impossible to reason about (see #2278/#2279), so it lives here
// where it can be unit-tested on any platform without a running NSApplication.
//
// ❌ NEVER import AppKit here. If you need an NSScreen or an NSWindow, read it
//    at the call site and pass the resulting CGRect in.
import CoreGraphics

// MARK: - Metrics

/// Fixed chrome dimensions for the anchored panel.
///
/// These describe the bubble we draw ourselves (see `MBKPanelMask`). They are
/// tuned to visually match the `NSPopover` chrome that MenuBarKit used to rely
/// on, so the app looks unchanged after the rewrite.
public struct MBKPanelMetrics: Equatable, Sendable {

    /// Height of the arrow that points up at the status item, in points.
    ///
    /// Doubles as the top content inset: content starts below the arrow.
    public var arrowHeight: CGFloat

    /// Width of the arrow base, in points.
    public var arrowWidth: CGFloat

    /// Corner radius of the bubble body, in points.
    public var cornerRadius: CGFloat

    /// Minimum gap kept between the panel and the edge of the visible frame, in points.
    public var screenMargin: CGFloat

    /// Creates a metrics value.
    /// - Parameters:
    ///   - arrowHeight: Height of the arrow, in points.
    ///   - arrowWidth: Width of the arrow base, in points.
    ///   - cornerRadius: Corner radius of the bubble body, in points.
    ///   - screenMargin: Minimum gap to the visible-frame edge, in points.
    public init(
        arrowHeight: CGFloat = 11,
        arrowWidth: CGFloat = 22,
        cornerRadius: CGFloat = 11,
        screenMargin: CGFloat = 8
    ) {
        self.arrowHeight = arrowHeight
        self.arrowWidth = arrowWidth
        self.cornerRadius = cornerRadius
        self.screenMargin = screenMargin
    }

    /// The metrics MenuBarKit uses unless an adopter overrides them.
    public static let `default` = MBKPanelMetrics()
}

// MARK: - Layout result

/// The fully resolved placement of the panel for one content size.
public struct MBKPanelLayout: Equatable, Sendable {

    /// Window frame in screen coordinates, including arrow chrome.
    public var frame: CGRect

    /// Horizontal centre of the arrow, in window-local coordinates.
    ///
    /// Normally `anchorX - frame.minX`, so the arrow tip stays under the status
    /// item even when the window itself had to be pushed away from a screen edge.
    public var arrowCenterX: CGFloat

    /// `true` when the window origin had to be moved to stay on screen.
    public var wasClamped: Bool

    /// Creates a layout value.
    /// - Parameters:
    ///   - frame: Window frame in screen coordinates.
    ///   - arrowCenterX: Arrow centre in window-local coordinates.
    ///   - wasClamped: Whether the origin was moved to stay on screen.
    public init(frame: CGRect, arrowCenterX: CGFloat, wasClamped: Bool) {
        self.frame = frame
        self.arrowCenterX = arrowCenterX
        self.wasClamped = wasClamped
    }
}

// MARK: - Geometry

/// Stateless frame math for the anchored panel.
///
/// The single source of truth for "given this content size and this anchor,
/// where does the window go". `MBKPanelController` never computes a frame by
/// hand — it calls `layout(...)` and applies the result verbatim.
public enum MBKPanelGeometry {

    /// Window size required to host a content rect of `content`.
    /// - Parameters:
    ///   - content: Size of the SwiftUI content, excluding chrome.
    ///   - metrics: Chrome metrics.
    /// - Returns: Window size including the arrow strip on top.
    public static func windowSize(forContent content: CGSize, metrics: MBKPanelMetrics) -> CGSize {
        CGSize(width: max(content.width, 0), height: max(content.height, 0) + metrics.arrowHeight)
    }

    /// Content height cap derived live from the screen.
    ///
    /// Computed on every open rather than once at launch — the launch-time
    /// snapshot was the root cause of the stale-cap bug in #2279.
    /// - Parameters:
    ///   - visibleFrame: The screen's visible frame.
    ///   - fraction: Fraction of the visible height the content may occupy.
    ///   - metrics: Chrome metrics; the arrow strip is subtracted from the cap.
    /// - Returns: Maximum content height in points, never negative.
    public static func maxContentHeight(
        visibleFrame: CGRect,
        fraction: CGFloat,
        metrics: MBKPanelMetrics
    ) -> CGFloat {
        max(visibleFrame.height * fraction - metrics.arrowHeight, 0)
    }

    /// Clamps a measured content size into the adopter's width/height limits.
    /// - Parameters:
    ///   - content: Measured content size.
    ///   - minWidth: Minimum allowed width.
    ///   - maxWidth: Maximum allowed width.
    ///   - maxHeight: Maximum allowed height.
    /// - Returns: The clamped size.
    public static func clampContent(
        _ content: CGSize,
        minWidth: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> CGSize {
        let width = min(max(content.width, minWidth), max(maxWidth, minWidth))
        let height = min(max(content.height, 0), max(maxHeight, 0))
        return CGSize(width: width, height: height)
    }

    /// Resolves the window frame and arrow position for one content size.
    ///
    /// Invariants, all exercised by `MBKPanelGeometryTests`:
    /// - The top edge is pinned: `frame.maxY == topY` for every content height,
    ///   so the panel grows downward and never detaches from the menu bar.
    /// - The window stays inside `visibleFrame` inset by `metrics.screenMargin`,
    ///   unless it is wider than the inset area, in which case it is centred.
    /// - `arrowCenterX` tracks the anchor but is kept far enough from the
    ///   corners that the arrow never overlaps the rounded corner radius.
    ///
    /// - Parameters:
    ///   - content: Content size, already clamped by `clampContent(_:...)`.
    ///   - anchorX: Horizontal centre of the status item, in screen coordinates.
    ///   - topY: Screen Y the top edge of the panel should touch.
    ///   - visibleFrame: The screen's visible frame.
    ///   - metrics: Chrome metrics.
    /// - Returns: The resolved layout.
    public static func layout(
        content: CGSize,
        anchorX: CGFloat,
        topY: CGFloat,
        visibleFrame: CGRect,
        metrics: MBKPanelMetrics
    ) -> MBKPanelLayout {
        let size = windowSize(forContent: content, metrics: metrics)

        let unclampedX = anchorX - size.width / 2
        let minX = visibleFrame.minX + metrics.screenMargin
        let maxX = visibleFrame.maxX - metrics.screenMargin - size.width
        let originX: CGFloat
        if maxX < minX {
            // Wider than the inset visible area — centre it and accept the overflow.
            originX = visibleFrame.midX - size.width / 2
        } else {
            originX = min(max(unclampedX, minX), maxX)
        }
        let wasClamped = abs(originX - unclampedX) > 0.5

        let arrowHalf = metrics.arrowWidth / 2
        let lowerBound = metrics.cornerRadius + arrowHalf
        let upperBound = size.width - metrics.cornerRadius - arrowHalf
        var arrowCenterX = anchorX - originX
        if upperBound >= lowerBound {
            arrowCenterX = min(max(arrowCenterX, lowerBound), upperBound)
        } else {
            arrowCenterX = size.width / 2
        }

        let frame = CGRect(x: originX, y: topY - size.height, width: size.width, height: size.height)
        return MBKPanelLayout(frame: frame, arrowCenterX: arrowCenterX, wasClamped: wasClamped)
    }
}
