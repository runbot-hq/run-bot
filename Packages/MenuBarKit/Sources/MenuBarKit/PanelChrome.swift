// PanelChrome.swift
// MenuBarKit
//
// v9
//
// DOUBLE-BACKGROUND FIX:
//   NSVisualEffectView (shadowCarrier) produced a second frosted slab even at
//   alphaValue=0.001. Removed entirely. NSGlassEffectView on an isOpaque=false
//   borderless window drives the window shadow by itself via the compositor —
//   no carrier needed.
//
// SQUARE-CORNER FIX:
//   addChildWindow resets the NSGlassEffectView compositing context. In addition
//   to re-setting .cornerRadius, we also clip the view's CALayer with a
//   CAShapeLayer mask so rounded corners are enforced at the CA level regardless
//   of what AppKit resets. reapplyGlassStyle() (called from AnchoredSheet after
//   addChildWindow) refreshes both.
//
// HIERARCHY:
//   MBKPanelChromeView        (plain NSView, window.contentView)
//     └── glassView           NSGlassEffectView  — fills chrome, liquid glass bg
//           └── contentView   MBKHostingView     — set by PanelController
//
// Per NSGlassEffectView.h: only contentView is clipped inside the glass shape.
// Arbitrary addSubview has undefined z-order and is NOT corner-clipped.
import AppKit

final class MBKPanelChromeView: NSView {

    // MARK: - Public
    /// Kept for API compatibility with PanelController+Frame.swift call-sites.
    var arrowCenterX: CGFloat = 0

    // MARK: - Private
    private let metrics: MBKPanelMetrics
    let glassView = NSGlassEffectView(frame: .zero)

    // MARK: - Init
    init(metrics: MBKPanelMetrics) {
        self.metrics = metrics
        super.init(frame: .zero)
        wantsLayer = true
        buildHierarchy()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Build
    private func buildHierarchy() {
        glassView.style        = .regular
        glassView.cornerRadius = metrics.cornerRadius
        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)

        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Layout
    override func layout() {
        super.layout()
        applyLayerMask(to: glassView, radius: metrics.cornerRadius)
    }

    // MARK: - Glass style (called by AnchoredSheet after addChildWindow)
    /// Re-applies cornerRadius at both the NSGlassEffectView and CALayer levels.
    /// addChildWindow resets the AppKit compositing context; the CALayer mask
    /// survives independently and keeps corners rounded even if AppKit hasn't
    /// re-applied its own state yet.
    func reapplyGlassStyle() {
        glassView.style        = .regular
        glassView.cornerRadius = metrics.cornerRadius
        applyLayerMask(to: glassView, radius: metrics.cornerRadius)
        window?.invalidateShadow()
    }

    // MARK: - Helpers
    private func applyLayerMask(to view: NSView, radius: CGFloat) {
        guard let layer = view.layer, layer.bounds.width > 0 else { return }
        let mask = CAShapeLayer()
        mask.path = CGPath(
            roundedRect: layer.bounds,
            cornerWidth: radius,
            cornerHeight: radius,
            transform: nil
        )
        layer.mask = mask
    }
}
