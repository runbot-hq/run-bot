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
/// These describe the bubble we draw ourselves. They are
/// tuned to visually match the chrome that MenuBarKit used to rely
/// on, so the app looks unchanged after the rewrite.
public struct MBKPanelMetrics: Equatable, Sendable {

    /// Corner radius of the bubble body, in points.
    public var cornerRadius: CGFloat

    /// Minimum gap kept between the panel and the edge of the visible frame, in points.
    public var screenMargin: CGFloat

    /// Creates a metrics value.
    /// - Parameters:
    ///   - cornerRadius: Corner radius of the bubble body, in points.
    ///   - screenMargin: Minimum gap to the visible-frame edge, in points.
    public init(
        cornerRadius: CGFloat = 11,
        screenMargin: CGFloat = 8
    ) {
        self.cornerRadius = cornerRadius
        self.screenMargin = screenMargin
    }

    /// The metrics MenuBarKit uses unless an adopter overrides them.
    public static let `default` = MBKPanelMetrics()

    /// Fallback content size used in openPanel() when preferredContentSize is zero.
    /// If this appears in FALLBACK log output during normal use, the measurement
    /// pipeline has not fired before first open — that is a bug, not expected behaviour.
    static let fallbackContentSize = CGSize(width: 320, height: 240)
}

// MARK: - Layout result

/// The fully resolved placement of the panel for one content size.
public struct MBKPanelLayout: Equatable, Sendable {

    /// Window frame in screen coordinates, including chrome.
    public var frame: CGRect

    /// `true` when the window origin had to be moved to stay on screen.
    public var wasClamped: Bool

    /// Creates a layout value.
    /// - Parameters:
    ///   - frame: Window frame in screen coordinates.
    ///   - wasClamped: Whether the origin was moved to stay on screen.
    public init(frame: CGRect, wasClamped: Bool) {
        self.frame = frame
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
    /// - Returns: Window size matching the content size exactly.
    public static func windowSize(forContent content: CGSize, metrics: MBKPanelMetrics) -> CGSize {
        CGSize(width: max(content.width, 0), height: max(content.height, 0))
    }

    /// Content height cap derived live from the drawable space below `topY`.
    ///
    /// Uses `topY - visibleFrame.minY` (the space the panel can actually occupy)
    /// rather than `visibleFrame.height` (the full visible screen height). This
    /// prevents the cap from exceeding the drawable space when the Dock, a
    /// secondary display, or a hidden menu bar shifts `topY` away from
    /// `visibleFrame.maxY`.
    ///
    /// Computed on every open rather than once at launch — the launch-time
    /// snapshot was the root cause of the stale-cap bug in #2279.
    /// - Parameters:
    ///   - topY: Screen Y that the top edge of the panel touches (= menu-bar bottom).
    ///   - visibleFrame: The screen's visible frame.
    ///   - fraction: Fraction of the drawable space the content may occupy.
    ///   - metrics: Chrome metrics.
    /// - Returns: Maximum content height in points, never negative.
    public static func maxContentHeight(
        topY: CGFloat,
        visibleFrame: CGRect,
        fraction: CGFloat,
        metrics: MBKPanelMetrics
    ) -> CGFloat {
        let drawable = topY - visibleFrame.minY
        return max(drawable * fraction, 0)
    }

    /// Content width cap derived live from the screen.
    ///
    /// The only width limit MenuBarKit imposes. An adopter-specific min/max width
    /// would apply to every route the adopter shows, so it belongs in the
    /// adopter's own views, not here.
    /// - Parameters:
    ///   - visibleFrame: The screen's visible frame.
    ///   - metrics: Chrome metrics; the screen margin is subtracted on both sides.
    /// - Returns: Maximum content width in points, never negative.
    public static func maxContentWidth(visibleFrame: CGRect, metrics: MBKPanelMetrics) -> CGFloat {
        max(visibleFrame.width - metrics.screenMargin * 2, 0)
    }

    /// Clamps a measured content size into the given width/height limits.
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

    /// Resolves the window frame for one content size.
    ///
    /// Invariants:
    /// - The top edge is pinned: `frame.maxY == topY` for every content height,
    ///   so the panel grows downward and never detaches from the menu bar.
    /// - `frame.minY >= visibleFrame.minY` — the panel never overflows above
    ///   the bottom of the visible area. If content height would push `minY`
    ///   below the floor, the window height is shrunk to fit and `wasClamped`
    ///   is set to `true`. (The AppKit cap in `applyMeasuredSize` should prevent
    ///   this in practice; the clamp here is a hard safety net.)
    /// - The window stays inside `visibleFrame` inset by `metrics.screenMargin`,
    ///   unless it is wider than the inset area, in which case it is centred.
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

        // Vertical floor: the panel must not extend below visibleFrame.minY.
        // topY is always held fixed (the panel grows downward), so if the window
        // would overflow the bottom of the visible area we shrink the height rather
        // than move topY. The AppKit cap in applyMeasuredSize prevents this in
        // normal operation; this clamp is a hard safety net for edge cases.
        let rawOriginY = topY - size.height
        let clampedOriginY = max(rawOriginY, visibleFrame.minY)
        let actualHeight = topY - clampedOriginY
        let wasClamped = (maxX < minX || abs(originX - unclampedX) > 0.5) || clampedOriginY != rawOriginY

        let frame = CGRect(x: originX, y: clampedOriginY, width: size.width, height: actualHeight)
        return MBKPanelLayout(frame: frame, wasClamped: wasClamped)
    }
}
