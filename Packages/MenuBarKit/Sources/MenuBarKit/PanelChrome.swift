// PanelChrome.swift
// MenuBarKit
//
// The panel's bubble, drawn in AppKit, underneath the SwiftUI content.
//
// WHY THE CHROME IS APPKIT AND NOT SwiftUI (read before "simplifying" this):
//
// 1. GLASS CANNOT SAMPLE GLASS. The first version of this wrapped the whole
//    hosted tree in `.glassEffect(.regular, in: MBKBubbleShape())`. That made
//    every `GlassEffectContainer` inside the adopter's content — metric bars,
//    status tags, every chip — render flat, because a SwiftUI glass ancestor
//    disables descendant glass. `NSPopover` never had this problem: its chrome
//    is window-level AppKit material, outside the SwiftUI glass system
//    entirely. Putting the bubble back at the AppKit layer restores exactly the
//    `NSPopover` topology, so the content renders as it does on `main`.
//    ❌ NEVER put a `.glassEffect(...)` back on the panel's root SwiftUI view.
//
// 2. CLICKS NEED PIXELS. macOS hit-tests borderless, non-opaque windows
//    per-pixel: a click on a pixel whose alpha is ~0 is delivered to whatever
//    is behind the window. SwiftUI glass over a fully clear window renders
//    near-zero alpha in places (especially at the rim), so clicks fell through,
//    the app beneath activated, and the workspace observer closed the panel.
//    `NSGlassEffectView` puts a real material — with real alpha — into the
//    window's backing store, and `dimmingAlpha` below guarantees a non-zero
//    floor inside the whole bubble the way `NSPopover`'s own base layer does.
//
// LAYERING — back to front, all inside the window's content view:
//
//   MBKPanelChromeView                     (this file, pinned edge-to-edge)
//   └── NSGlassEffectContainerView         merges the two glass views below
//       └── plain NSView (its contentView)
//           ├── NSGlassEffectView          body: window minus the arrow strip
//           └── NSGlassEffectView          arrow: square, rotated 45°
//   MBKHostingView                         (pinned edge-to-edge, on top)
//
// THE ARROW. `NSGlassEffectView` exposes `cornerRadius` and nothing else, so it
// cannot describe a triangle. Instead the arrow is a square glass view rotated
// 45° about its centre, with that centre sitting exactly on the body's top
// edge: the half above the edge is a 90° isoceles triangle, the half below is
// swallowed by the body. `NSGlassEffectContainerView` merges the two into one
// continuous liquid shape — that is its documented purpose — so there is no
// seam between the arrow and the bubble.
//
// The rotated square's visible extent is `arrowHeight` tall and
// `2 * arrowHeight` wide, so the rendered arrow is always a right isoceles
// triangle. `MBKPanelMetrics.arrowWidth` (22 for the default 11pt height) still
// describes the SwiftUI clip silhouette and the geometry clamps; the two agree
// for the default metrics, and the clamp below uses the rendered half-width so
// they cannot disagree here either.
//
// ❌ NEVER go back to `NSVisualEffectView` + `maskImage`. That is pre-macOS-26
//    vibrancy, not Liquid Glass.
// ❌ NEVER use Auto Layout for the two glass views. `frameCenterRotation` and
//    Auto Layout do not mix; this view lays its children out by hand in
//    `layout()` and is itself the only thing the window constrains.
import AppKit

/// The panel's Liquid Glass bubble and arrow, drawn below the hosted SwiftUI content.
///
/// Pinned edge-to-edge to the window's content view. The window frame is the
/// bubble's bounding box: the body fills everything below the top
/// `metrics.arrowHeight` strip, and the arrow pokes up into that strip at
/// `arrowCenterX`.
final class MBKPanelChromeView: NSView {

    // MARK: - Constants

    /// Alpha of the flat fill placed inside each glass view.
    ///
    /// Two jobs, both load-bearing:
    /// - It is the minimum alpha the window's backing store carries inside the
    ///   bubble, which is what stops macOS delivering clicks straight through
    ///   the panel to the window beneath it.
    /// - It is the same kind of dimming base `NSPopover` puts under its own
    ///   material, so the glass reads as a surface rather than a smear.
    ///
    /// Deliberately small enough to be visually imperceptible but far enough
    /// above zero to survive 8-bit quantisation of the backing store.
    private static let dimmingAlpha: CGFloat = 0.02

    /// Ratio between a square's diagonal and its side.
    ///
    /// The arrow is a square rotated 45°, so a square of side
    /// `arrowHeight * diagonalRatio` presents exactly `arrowHeight` of height
    /// above the body edge and `2 * arrowHeight` of base width.
    private static let diagonalRatio: CGFloat = 2.0.squareRoot()

    // MARK: - Configuration

    /// Chrome metrics — arrow size and corner radius.
    private let metrics: MBKPanelMetrics

    /// Arrow centre in window-local points, measured from the leading edge.
    ///
    /// Written by `applyFrame(content:reason:)` from `MBKPanelGeometry.layout`,
    /// the same value handed to the SwiftUI clip shape, so the AppKit arrow and
    /// the content clip can never point at different places.
    var arrowCenterX: CGFloat = 0 {
        didSet {
            guard abs(arrowCenterX - oldValue) >= 0.5 else { return }
            needsLayout = true
        }
    }

    // MARK: - Subviews

    /// Merges the body and the arrow into one continuous glass shape.
    private let container = NSGlassEffectContainerView(frame: .zero)

    /// Plain holder assigned to `container.contentView`; the glass views are its subviews.
    private let containerContent = NSView(frame: .zero)

    /// The bubble body: everything below the arrow strip.
    private let bodyGlass = NSGlassEffectView(frame: .zero)

    /// The arrow: a square rotated 45° whose centre sits on the body's top edge.
    private let arrowGlass = NSGlassEffectView(frame: .zero)

    /// Minimum-alpha fill inside the body glass. See `dimmingAlpha`.
    private let bodyFill: NSView

    /// Minimum-alpha fill inside the arrow glass. See `dimmingAlpha`.
    private let arrowFill: NSView

    // MARK: - Init

    /// Creates the chrome view.
    /// - Parameter metrics: Bubble chrome metrics.
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

        // Zero already batches the two views, and the arrow overlaps the body
        // so any non-negative spacing merges them. One arrow height is a
        // deliberate margin against rounding at fractional backing scales.
        container.spacing = max(metrics.arrowHeight, 0)
        containerContent.addSubview(arrowGlass)
        containerContent.addSubview(bodyGlass)
        container.contentView = containerContent
        addSubview(container)
    }

    /// Not supported — the panel is built in code.
    /// - Parameter coder: Unused.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - Layout

    /// Lays the body and the arrow out by hand.
    ///
    /// The guard at the very top of the method ensures no `NSGlassEffectView`
    /// frame is ever assigned until `bounds` is a valid, positive-size rect.
    /// At the first AppKit layout pass the window has no real frame yet, so
    /// `bounds` is `.zero`; `NSGlassEffectView` raises an internal geometry
    /// assertion (`Invalid view geometry: y is NaN` → `EXC_BREAKPOINT`) when
    /// handed a zero-dimension frame. All frame writes therefore live below the
    /// guard — never above it.
    ///
    /// `frameCenterRotation` is reset to zero before the arrow's frame is
    /// assigned and re-applied afterwards: while a view is rotated, `frame` is
    /// the *bounding box* of the rotated bounds, so assigning it directly would
    /// shrink the square a little more on every pass.
    override func layout() {
        super.layout()

        // Guard the entire method before touching any NSGlassEffectView.
        // At the first AppKit layout pass the window has no real frame yet,
        // so bounds is .zero; NSGlassEffectView raises on a zero-dimension frame.
        let arrowHeight = max(metrics.arrowHeight, 0)
        let bodyHeight  = bounds.height - arrowHeight
        guard bounds.width > 0, bodyHeight > 0, arrowHeight > 0,
              bounds.width.isFinite, bodyHeight.isFinite,
              bounds.minX.isFinite, bounds.minY.isFinite else {
            arrowGlass.isHidden = true
            bodyGlass.isHidden  = true
            return
        }

        bodyGlass.isHidden  = false
        arrowGlass.isHidden = false

        let body = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: bodyHeight
        )
        let radius = min(max(metrics.cornerRadius, 0), min(body.width, body.height) / 2)

        container.frame        = bounds
        containerContent.frame = bounds
        bodyGlass.frame        = body
        bodyGlass.cornerRadius = radius
        bodyFill.frame         = bodyGlass.bounds

        // The rendered arrow is `arrowHeight` tall and twice that wide, so the
        // clamp uses the rendered half-width, not `metrics.arrowWidth`.
        let lower  = body.minX + radius + arrowHeight
        let upper  = body.maxX - radius - arrowHeight
        let centre = upper >= lower ? min(max(arrowCenterX, lower), upper) : body.midX

        let side = arrowHeight * MBKPanelChromeView.diagonalRatio
        arrowGlass.frameCenterRotation = 0
        arrowGlass.frame = CGRect(
            x: centre - side / 2,
            y: body.maxY - side / 2,
            width: side,
            height: side
        )
        arrowFill.frame                = arrowGlass.bounds
        arrowGlass.frameCenterRotation = 45
    }

    // MARK: - Helpers

    /// Builds the near-transparent fill embedded in a glass view.
    /// - Returns: A layer-backed view sized by its glass host in `layout()`.
    private static func makeFill() -> NSView {
        let fill = NSView(frame: .zero)
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.black.withAlphaComponent(dimmingAlpha).cgColor
        fill.autoresizingMask = [.width, .height]
        return fill
    }
}
