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
// SHAPE STRATEGY — WHY NSVisualEffectView + maskImage:
//
// `NSVisualEffectView.maskImage` is processed by the window server before
// compositing. It survives addChildWindow (sheet presentation) because it lives
// at the window-server level, not the AppKit layer tree. This is the ONLY public
// API that keeps the panel shaped when a sheet child window is attached.
//
// CAShapeLayer.mask on contentView.layer does NOT survive addChildWindow:
// addChildWindow changes the compositing context, causing NSGlassEffectView to
// recreate its backing CALayer and discard any layer.mask set on it.
//
// The NSVisualEffectView is material=.hudWindow, alphaValue=0 — it contributes
// zero visible rendering of its own. It exists only as the maskImage carrier.
// NSGlassEffectView (style=.regular) is a subview of it and provides the actual
// Liquid Glass material surface.
//
// This matches what f18cdd4 proved worked (NSVisualEffectView + maskImage +
// NSGlassEffectView on top), and is why the shadow follows the bubble for free.
//
// ❌ NEVER replace the NSVisualEffectView with a plain NSView — maskImage is a
//    NSVisualEffectView property; plain views have no equivalent.
// ❌ NEVER use NSGlassEffectContainerView here — its border doubles.
// ❌ NEVER put .glassEffect(...) on the SwiftUI root view.
import AppKit

/// The panel's Liquid Glass bubble drawn below the hosted SwiftUI content.
///
/// Acts as the window's `contentView`. Carries the `maskImage` that shapes both
/// the rendered glass and the window shadow at the window-server level.
final class MBKPanelChromeView: NSVisualEffectView {

    // MARK: - Constants

    /// Minimum alpha floor on the glass fill — prevents click-through on edges.
    private static let dimmingAlpha: CGFloat = 0.02

    // MARK: - Properties

    private let metrics: MBKPanelMetrics

    /// Arrow centre in window-local points (from leading edge).
    /// Setting this regenerates the maskImage and redraws the bubble.
    var arrowCenterX: CGFloat = 0 {
        didSet {
            guard abs(arrowCenterX - oldValue) >= 0.5 else { return }
            updateMask()
        }
    }

    // MARK: - Subviews

    private let glass = NSGlassEffectView(frame: .zero)
    private let fill: NSView

    // MARK: - Init

    init(metrics: MBKPanelMetrics) {
        self.metrics = metrics
        self.fill = MBKPanelChromeView.makeFill()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The NSVisualEffectView exists solely as the maskImage carrier.
        // alphaValue must stay 1 — a zero-alpha window has no hit-test area and
        // every click falls through, firing the outside-click monitor immediately.
        // .underWindowBackground is the most transparent built-in material;
        // NSGlassEffectView on top visually dominates so the material is invisible.
        material = .underWindowBackground
        blendingMode = .behindWindow
        state = .active

        glass.style = .regular
        glass.frame = .zero
        glass.autoresizingMask = [.width, .height]
        glass.contentView = fill
        addSubview(glass)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard bounds.width > 0, bounds.height > 0 else { return }
        glass.frame = bounds
        fill.frame = glass.bounds
        updateMask()
    }

    // MARK: - Mask

    /// Regenerates the maskImage from the current bounds and arrowCenterX.
    ///
    /// Called from `layout()` and from the `arrowCenterX` didSet so the mask is
    /// always in sync with the window frame. The maskImage is set on self
    /// (NSVisualEffectView), which forwards it to the window server — making it
    /// survive addChildWindow and the compositing-context changes that come with it.
    private func updateMask() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        maskImage = MBKPanelMask.image(
            size: bounds.size,
            arrowCenterX: arrowCenterX,
            metrics: metrics,
            scale: scale
        )
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
