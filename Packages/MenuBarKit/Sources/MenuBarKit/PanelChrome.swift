// PanelChrome.swift
// MenuBarKit
//
// The panel's Liquid Glass bubble, drawn in AppKit below the SwiftUI content.
//
// WHY THE CHROME IS APPKIT AND NOT SwiftUI:
//
// 1. GLASS CANNOT SAMPLE GLASS. `.glassEffect(.regular, in: bubble)` on the
//    root flattens every GlassEffectContainer in the adopter's content.
//    \u274c NEVER put `.glassEffect(...)` on the panel's root SwiftUI view.
//
// 2. CLICKS NEED PIXELS. macOS hit-tests borderless non-opaque windows
//    per-pixel. Near-zero-alpha SwiftUI glass at the rim lets clicks fall
//    through, firing the workspace observer and closing the panel.
//    \u274c NEVER rely on SwiftUI alpha alone for hit-testing.
//
// LAYERING (back to front, inside the window's content view):
//
//   MBKPanelChromeView                     pinned edge-to-edge
//   \u251c\u2500\u2500 NSGlassEffectContainerView         body glass
//   \u2502   \u2514\u2500\u2500 NSGlassEffectView (bodyGlass)    rounded-rect body
//   \u2514\u2500\u2500 NSGlassEffectView (arrowGlass)        triangle arrow, sibling
//   MBKHostingView                         pinned on top
//
// ARROW SHAPE:
// NSGlassEffectView only exposes `cornerRadius`. The old approach rotated a
// square 45\u00b0 via CATransform3D which produced a right-isosceles triangle, but
// its rendered width (2*arrowHeight) was always wider than `arrowWidth` (22pt
// at default 11pt height) and couldn\u2019t match the SwiftUI clip exactly.
//
// New approach: arrowGlass is an unrotated rectangle covering the arrow strip,
// masked to the exact isosceles triangle via a CAShapeLayer on its layer.
// Frame stays axis-aligned \u2192 the AppKit layout engine never sees NaN geometry.
// The triangle path mirrors MBKBubbleShape so chrome and clip are pixel-identical.
//
// \u274c NEVER use frameCenterRotation or CATransform3D rotation for arrowGlass.
// \u274c NEVER go back to NSVisualEffectView + maskImage. Pre-macOS-26 vibrancy.
import AppKit

/// The panel\u2019s Liquid Glass bubble drawn below the hosted SwiftUI content.
final class MBKPanelChromeView: NSView {

    // MARK: - Constants

    /// Minimum alpha floor \u2014 prevents click-through on panel edges.
    private static let dimmingAlpha: CGFloat = 0.02

    // MARK: - Subviews

    private let metrics: MBKPanelMetrics
    private let container = NSGlassEffectContainerView(frame: .zero)
    private let bodyGlass = NSGlassEffectView(frame: .zero)
    private let arrowGlass = NSGlassEffectView(frame: .zero)
    private let bodyFill: NSView
    private let arrowFill: NSView

    /// CAShapeLayer mask applied to arrowGlass.layer to clip it to the triangle.
    private let arrowMask = CAShapeLayer()

    // MARK: - State

    /// Arrow centre in window-local points (from leading edge).
    var arrowCenterX: CGFloat = 0 {
        didSet {
            guard abs(arrowCenterX - oldValue) >= 0.5 else { return }
            needsLayout = true
        }
    }

    // MARK: - Init

    init(metrics: MBKPanelMetrics) {
        self.metrics = metrics
        self.bodyFill = MBKPanelChromeView.makeFill()
        self.arrowFill = MBKPanelChromeView.makeFill()
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        bodyGlass.style = .regular
        arrowGlass.style = .regular
        bodyGlass.contentView = bodyFill
        arrowGlass.contentView = arrowFill
        arrowGlass.wantsLayer = true

        // bodyGlass inside the container for correct Liquid Glass merging.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bodyGlass)

        // arrowGlass is a sibling of the container, NOT inside it.
        // Being outside prevents the container\u2019s internal layout pass from
        // ever touching arrowGlass \u2014 which avoids the y=NaN crash.
        addSubview(container)
        addSubview(arrowGlass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let arrowH = max(metrics.arrowHeight, 0)
        let body = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(bounds.height - arrowH, 0)
        )
        let radius = min(max(metrics.cornerRadius, 0), min(body.width, body.height) / 2)

        container.frame = body
        bodyGlass.frame = CGRect(origin: .zero, size: body.size)
        bodyGlass.cornerRadius = radius
        bodyFill.frame = bodyGlass.bounds

        guard arrowH > 0, body.width > 0 else {
            arrowGlass.isHidden = true
            return
        }
        arrowGlass.isHidden = false

        let half = max(metrics.arrowWidth, 0) / 2
        let lower = body.minX + radius + half
        let upper = body.maxX - radius - half
        let centre = upper >= lower
            ? min(max(arrowCenterX, lower), upper)
            : body.midX

        // Arrow strip: full-width band at top of window, height = arrowH.
        // The CAShapeLayer mask clips it to the isosceles triangle.
        let arrowRect = CGRect(
            x: centre - half,
            y: body.maxY,
            width: half * 2,
            height: arrowH
        )
        arrowGlass.frame = arrowRect
        arrowFill.frame = arrowGlass.bounds
        arrowGlass.cornerRadius = 0

        // Mask: triangle in arrowGlass\u2019s own coordinate space.
        // Origin is bottom-left of arrowRect; apex at top-centre.
        let triPath = CGMutablePath()
        triPath.move(to:    CGPoint(x: 0,        y: 0))
        triPath.addLine(to: CGPoint(x: half,     y: arrowH))
        triPath.addLine(to: CGPoint(x: half * 2, y: 0))
        triPath.closeSubpath()

        arrowMask.frame = arrowGlass.bounds
        arrowMask.path = triPath
        arrowGlass.layer?.mask = arrowMask
    }

    // MARK: - Helpers

    private static func makeFill() -> NSView {
        let v = NSView(frame: .zero)
        v.wantsLayer = true
        v.layer?.backgroundColor =
            NSColor.black.withAlphaComponent(dimmingAlpha).cgColor
        v.autoresizingMask = [.width, .height]
        return v
    }
}
