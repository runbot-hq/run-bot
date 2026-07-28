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
//   ├── NSGlassEffectContainerView         merges body+arrow into one surface
//   │   └── NSGlassEffectView              body: window minus the arrow strip
//   └── NSGlassEffectView                  arrow: square, rotated 45° via CA
//   MBKHostingView                         (pinned edge-to-edge, on top)
//
// WHY THE ARROW IS OUTSIDE THE CONTAINER:
// NSGlassEffectContainerView fires its own internal layout pass on its *direct*
// children whenever AppKit lays it out. When arrowGlass was inside the container
// and we applied frameCenterRotation=45, that internal pass ran on the rotated
// view and produced y=NaN -> _NSViewValidateGeometry crash. The fix is:
//   1. bodyGlass lives inside the container  → glass renders correctly.
//   2. arrowGlass is a sibling of the container → the container never touches
//      it, so no NaN. arrowGlass is rotated via CATransform3D (pure CA, the
//      layout engine never sees it).
// The container still produces the correct merged glass shape for the body.
// The arrow is a separate glass tile; it is visually seamless because it sits
// directly on top of the body edge and uses the same .regular style.
//
// THE ARROW. `NSGlassEffectView` exposes `cornerRadius` and nothing else, so it
// cannot describe a triangle. Instead the arrow is a square glass view rotated
// 45° about its centre, with that centre sitting exactly on the body's top
// edge: the half above the edge is a 90° isoceles triangle, the half below is
// swallowed by the body.
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
// ❌ NEVER use Auto Layout for the two glass views, and NEVER use
//    `frameCenterRotation` for arrowGlass. Both cause AppKit's layout engine
//    to compute NaN geometry inside NSGlassEffectView's internal layout pass.
//    The arrow is rotated via CATransform3D on its layer instead (pure CA,
//    invisible to the layout engine). This view lays its children out by hand
//    in `layout()` and is itself the only thing the window constrains.
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

    /// Container that makes `bodyGlass` render as Liquid Glass.
    ///
    /// `arrowGlass` is intentionally NOT added to this container — see the
    /// layering note at the top of the file.
    private let container = NSGlassEffectContainerView(frame: .zero)

    /// The bubble body: everything below the arrow strip.
    private let bodyGlass = NSGlassEffectView(frame: .zero)

    /// The arrow: a square rotated 45° via CATransform3D, sibling of container.
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
        arrowGlass.wantsLayer = true

        // bodyGlass inside the container so it gets real Liquid Glass rendering.
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bodyGlass)

        // arrowGlass is a direct child of self, NOT inside the container.
        // This keeps it out of the container's internal layout pass so it
        // never receives a NaN frame. It is added after the container so it
        // paints on top, covering the seam at the body's top edge.
        addSubview(container)
        addSubview(arrowGlass)
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
    /// The arrow's 45° rotation is applied via `CATransform3D` on the layer,
    /// NOT via `frameCenterRotation`. `frameCenterRotation` causes AppKit's
    /// layout engine to see the rotated bounding-box as the view's frame,
    /// which produces `y = NaN` inside `NSGlassEffectView`'s own internal
    /// layout pass whenever the window resizes. A layer transform is invisible
    /// to the layout engine — the frame stays as the plain unrotated square —
    /// so AppKit never computes NaN geometry.
    override func layout() {
        super.layout()

        let arrowHeight = max(metrics.arrowHeight, 0)
        let body = CGRect(
            x: bounds.minX,
            y: bounds.minY,
            width: bounds.width,
            height: max(bounds.height - arrowHeight, 0)
        )
        let radius = min(max(metrics.cornerRadius, 0), min(body.width, body.height) / 2)

        // The container must match the body exactly so the glass effect
        // samples the correct region of the screen behind the window.
        container.frame = body
        bodyGlass.frame = CGRect(origin: .zero, size: body.size)
        bodyGlass.cornerRadius = radius
        bodyFill.frame = bodyGlass.bounds

        guard arrowHeight > 0, body.width > 0, body.height > 0 else {
            arrowGlass.isHidden = true
            container.isHidden = false  // body still visible even without arrow
            return
        }
        arrowGlass.isHidden = false
        container.isHidden = false

        // The rendered arrow is `arrowHeight` tall and twice that wide, so the
        // clamp uses the rendered half-width, not `metrics.arrowWidth`.
        let lower = body.minX + radius + arrowHeight
        let upper = body.maxX - radius - arrowHeight
        let centre = upper >= lower ? min(max(arrowCenterX, lower), upper) : body.midX

        let side = arrowHeight * MBKPanelChromeView.diagonalRatio
        // Set frame as a plain unrotated square. The layout engine only sees
        // this rect — never NaN — and the visual rotation is pure CA.
        arrowGlass.frame = CGRect(
            x: centre - side / 2,
            y: body.maxY - side / 2,
            width: side,
            height: side
        )
        arrowFill.frame = arrowGlass.bounds
        // Zero corner radius so the rotated square has sharp corners and
        // renders as a clean triangle tip, not a pill/circle.
        arrowGlass.cornerRadius = 0
        // Rotate 45° via layer transform so AppKit's layout engine is never
        // involved in the rotation. CATransform3DMakeRotation takes radians.
        arrowGlass.layer?.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
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
