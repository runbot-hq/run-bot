// PanelBubbleShape.swift
// MenuBarKit
//
// The panel's silhouette: a rounded rectangle with an arrow poking out of its
// top edge, expressed as a SwiftUI `Shape`.
//
// WHAT THIS IS FOR, AND WHAT IT IS NOT FOR:
// This is the *clip* for the hosted content, and the geometry the unit tests
// pin down. It is NOT the chrome. The Liquid Glass material is `NSGlassEffectView`,
// which is the direct panel.contentView — the hosting view sits above it as a
// plain addSubview sibling, outside the glass compositor, so the adopter's
// own .glassEffect elements work correctly.
//
// ❌ NEVER pass this shape to `.glassEffect(_:in:)` on the panel root.
//    A SwiftUI glass ancestor flattens all GlassEffectContainer content inside it.
// ❌ NEVER go back to `NSVisualEffectView.maskImage` for the chrome. It is flat
//    pre-26 translucency, not Liquid Glass.
//
// COORDINATE SPACE:
// SwiftUI, so the origin is top-left and Y grows downward. `arrowCenterX` is
// measured from the leading edge of the rect and is produced by
// `MBKPanelGeometry.layout(...)` in window-local points — the two agree because
// the hosting view is pinned edge-to-edge to the window's content view.
import SwiftUI

/// Rounded-rectangle bubble with an arrow on its top edge.
///
/// The body occupies everything below `arrowHeight`; the arrow is an isoceles
/// triangle whose base sits exactly on the body's top edge, so the two subpaths
/// touch without overlapping and the non-zero winding rule cannot punch a seam.
///
/// Used as `.clipShape(...)` on the panel's content. The matching material is
/// `NSGlassEffectView` (the direct `panel.contentView`), which uses the same
/// `cornerRadius` from `MBKPanelMetrics`.
struct MBKBubbleShape: Shape {

    /// Arrow centre, in points from the leading edge of the rect.
    var arrowCenterX: CGFloat

    /// Height of the arrow, in points. Doubles as the body's top inset.
    var arrowHeight: CGFloat

    /// Width of the arrow base, in points.
    var arrowWidth: CGFloat

    /// Corner radius of the bubble body, in points.
    var cornerRadius: CGFloat

    /// Animates the arrow horizontally so an edge-clamped panel slides its arrow
    /// rather than jumping it.
    var animatableData: CGFloat {
        get { arrowCenterX }
        set { arrowCenterX = newValue }
    }

    /// Builds the bubble outline for the given rect.
    /// - Parameter rect: The area the shape is asked to fill.
    /// - Returns: The bubble path, arrow included.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let arrowInset = min(max(arrowHeight, 0), rect.height)
        let body = CGRect(
            x: rect.minX,
            y: rect.minY + arrowInset,
            width: rect.width,
            height: max(rect.height - arrowInset, 0)
        )
        let radius = min(max(cornerRadius, 0), min(body.width, body.height) / 2)
        path.addRoundedRect(
            in: body,
            cornerSize: CGSize(width: radius, height: radius),
            style: .continuous
        )

        let half = min(max(arrowWidth, 0) / 2, body.width / 2)
        guard arrowInset > 0, half > 0 else { return path }

        // Keep the arrow base clear of the rounded corners; the same clamp is
        // applied to `arrowCenterX` in MBKPanelGeometry — this is belt-and-braces
        // for the degenerate case where the panel is narrower than two corners.
        let lower = body.minX + radius + half
        let upper = body.maxX - radius - half
        let centre = upper >= lower ? min(max(arrowCenterX, lower), upper) : body.midX

        path.move(to: CGPoint(x: centre - half, y: body.minY))
        path.addLine(to: CGPoint(x: centre, y: rect.minY))
        path.addLine(to: CGPoint(x: centre + half, y: body.minY))
        path.closeSubpath()
        return path
    }
}
