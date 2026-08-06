// SettingsTintedGlassCard.swift
// RunBot
import SwiftUI

// MARK: - SettingsTintedGlassCard

/// Settings-local Liquid Glass modifier that preserves a coloured background
/// surface beneath plain `.regular` glass.
///
/// This modifier follows the same pattern as RunBot's working badge and metric
/// components: the colour is applied as a `.background` fill on the shape first,
/// then `.glassEffect(.regular, in:)` is layered on top. This lets the glass
/// refractive layer sample the backdrop **and** tint from the solid colour fill,
/// producing a visually rich result.
///
/// ⚠️ Do NOT use `.regular.tint(_:)` here. Passing a low-opacity colour into
/// `Glass.tint` yields a weak, dull result. Retain the colour as a background.
///
/// Scope: settings authentication and install/update cards only.
/// Do NOT move this to `DesignSystem` or use it outside the Settings target.
struct SettingsTintedGlassCard: ViewModifier {
    /// The colour used as the card's background surface.
    let backgroundColor: Color
    /// Corner radius for the continuous rounded-rectangle shape. Defaults to 8.
    let cornerRadius: CGFloat

    /// Applies the coloured background and Liquid Glass effect to the content.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(backgroundColor, in: shape)
            .glassEffect(.regular, in: shape)
    }
}

// MARK: - View convenience
extension View {
    /// Applies the settings-local tinted glass card modifier.
    ///
    /// - Parameters:
    ///   - backgroundColor: The colour surface to preserve beneath the glass.
    ///   - cornerRadius: Corner radius of the continuous rounded rectangle. Defaults to 8.
    func settingsTintedGlassCard(
        backgroundColor: Color,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(
            SettingsTintedGlassCard(
                backgroundColor: backgroundColor,
                cornerRadius: cornerRadius
            )
        )
    }
}
