// PanelChrome.swift
// MenuBarKit
//
// The panel's Liquid Glass bubble, drawn in AppKit below the SwiftUI content.
//
// WHY THE CHROME IS APPKIT AND NOT SwiftUI:
//
// 1. GLASS CANNOT SAMPLE GLASS. `.glassEffect(.regular, in: bubble)` on the
//    root flattens every GlassEffectContainer inside the adopter's content.
//    ❌ NEVER put `.glassEffect(...)` on the panel's root SwiftUI view.
//
// 2. CLICKS NEED PIXELS. macOS hit-tests borderless non-opaque windows per-pixel.
//    Near-zero-alpha SwiftUI glass at the rim lets clicks fall through, firing
//    the workspace observer and closing the panel.
//    ❌ NEVER rely on SwiftUI alpha alone for hit-testing.
//
// SHAPE STRATEGY:
// One NSGlassEffectView fills the whole chrome view. Its layer is masked to the
// bubble silhouette (rounded-rect body + isosceles triangle arrow) via a
// CAShapeLayer. This produces one seamless glass surface with the correct arrow
// shape and no second border.
//
// NSGlassEffectContainerView is intentionally NOT used here: it renders its own
// composite border outline that produced the double-background artifact. A plain
// NSGlassEffectView with a layer mask gives the same material without the extra
// border.
//
// The bubble path mirrors MBKBubbleShape exactly (AppKit CG coords: origin
// bottom-left, body at minY, arrow tip at maxY) so the AppKit chrome and the
// SwiftUI clipShape are pixel-identical.
//
// ❌ NEVER go back to NSVisualEffectView + maskImage. Pre-macOS-26 vibrancy.
// ❌ NEVER use NSGlassEffectContainerView for this view — its border doubles.
import AppKit

/// The panel's Liquid Glass bubble drawn below the hosted SwiftUI content.
///
/// Pinned edge-to-edge to the window's content view. One NSGlassEffectView fills
/// the whole view; a CAShapeLayer mask clips it to the bubble silhouette.
final class MBKPanelChromeView: NSView {

    // MARK: - Constants

    /// Minimum alpha floor — prevents click-through on panel edges.
    private static let dimmingAlpha: CGFloat = 0.02

    // MARK: - Properties

    private let metrics: MBKPanelMetrics

    /// Arrow centre in window-local points (from leading edge).
    var arrowCenterX: CGFloat = 0 {
        didSet {
            guard abs(arrowCenterX - oldValue) >= 0.5 else { return }
            needsLayout = true
        }
    }

    // MARK: - Subviews

    private let glass = NSGlassEffectView(frame: .zero)
    private let fill: NSView
    private let maskLayer = CAShapeLayer()

    // MARK: - Init

    init(metrics: MBKPanelMetrics) {
        self.metrics = metrics
        self.fill = MBKPanelChromeView.makeFill()
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        glass.style = .regular
        glass.contentView = fill
        glass.wantsLayer = true
        glass.layer?.mask = maskLayer
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }

        // Glass fills the entire chrome view; the mask does all shaping.
        glass.frame = bounds
        glass.cornerRadius = 0  // mask handles shape; no built-in radius needed
        fill.frame = glass.bounds

        maskLayer.frame = bounds
        maskLayer.path = bubblePath(in: bounds)
    }

    // MARK: - Bubble path

    /// Builds the bubble CGPath in AppKit/CG coordinates (origin bottom-left, Y up).
    /// Body at minY, arrow tip at maxY. Mirrors MBKBubbleShape exactly.
    private func bubblePath(in rect: CGRect) -> CGPath {
        let arrowH = max(metrics.arrowHeight, 0)
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(rect.height - arrowH, 0)
        )
        let radius = min(max(metrics.cornerRadius, 0), min(body.width, body.height) / 2)

        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: radius, cornerHeight: radius)

        let half = max(metrics.arrowWidth, 0) / 2
        guard arrowH > 0, half > 0 else { return path }

        let lower = body.minX + radius + half
        let upper = body.maxX - radius - half
        let centre = upper >= lower
            ? min(max(arrowCenterX, lower), upper)
            : body.midX

        // Arrow: base on body.maxY, apex at rect.maxY.
        path.move(to:    CGPoint(x: centre - half, y: body.maxY))
        path.addLine(to: CGPoint(x: centre,        y: rect.maxY))
        path.addLine(to: CGPoint(x: centre + half, y: body.maxY))
        path.closeSubpath()
        return path
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
