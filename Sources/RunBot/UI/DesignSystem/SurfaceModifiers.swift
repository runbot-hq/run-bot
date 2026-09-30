// SurfaceModifiers.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular)` — passive containers must NOT
/// use `.interactive()`. The LiquidGlassReference guide restricts `.interactive()`
/// to tappable controls (buttons, icons) only. Applying it to a passive container
/// activates scaling/shimmer on the entire card surface including non-interactive
/// children, which is semantically wrong and wastes GPU compositing budget.
/// Tappable rows handle interactivity at the contentShape/button level.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT add `.interactive()` back to GlassCard — see #963.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat
    /// Opacity of the fallback stroke border. Defaults to 0.15; use 0.25 for sections.
    var strokeOpacity: Double

    /// Creates a `GlassCard` modifier with custom corner radius and stroke opacity.
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }

    /// Applies the glass card effect to the given content view.
    @ViewBuilder
    func body(content: Content) -> some View {
       content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

// MARK: - View extensions
/// Convenience modifiers for applying design-system glass effects and backgrounds.
extension View {
    /// Applies the `GlassCard` modifier with the given corner radius.
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }
}

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card").padding().glassCard()
        Text("Glass Card r=10").padding().glassCard(cornerRadius: 10)
    }.padding()
}
#endif
