// SettingsTintedGlassCard.swift
// RunBot
import SwiftUI

// MARK: - SettingsTintedGlassCard

/// Settings-local Liquid Glass modifier shared by tinted and pre-resolved backgrounds.
///
/// Two entry points:
/// - `settingsTintedGlassCard(color:cornerRadius:)` — accepts an undimmed semantic color
///   and applies `opacity(0.15)` internally. Use for semantic colors like `.rbDanger`.
/// - `settingsGlassCard(background:cornerRadius:)` — accepts a final resolved background
///   color (e.g. `.rbGlassNeutralBackground`, `.rbAuthActiveGlassBackground`) and applies
///   no additional opacity. Use when the token already contains its opacity.
///
/// Both paths share one rendering implementation:
///
///     content
///         .background(backgroundColor, in: shape)
///         .glassEffect(.regular, in: shape)
///
/// ⚠️ Do NOT pass a pre-dimmed adaptive token to `settingsTintedGlassCard` — use
///    `settingsGlassCard(background:)` instead to avoid double-opacity multiplication.
/// ⚠️ Do NOT use `.regular.tint`. The background approach produces visibly native glass.
///
/// Scope: settings authentication and install/update cards only.
/// Do NOT move this to `DesignSystem` or use it outside Settings.
struct SettingsTintedGlassCard: ViewModifier {
    /// Final resolved background color applied directly (no additional opacity).
    let backgroundColor: Color
    /// Corner radius for the continuous rounded-rectangle shape. Defaults to 8.
    let cornerRadius: CGFloat

    /// Applies the badge-pattern glass effect to the content.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(backgroundColor, in: shape)
            .glassEffect(.regular, in: shape)
    }
}

/// Convenience modifier accessors for ``SettingsTintedGlassCard``.
extension View {
    /// Applies the settings-local glass card with an undimmed semantic color.
    /// `opacity(0.15)` is applied internally — do NOT pre-dim the color.
    ///
    /// - Parameters:
    ///   - color: Base semantic color (undimmed). `opacity(0.15)` is applied internally.
    ///   - cornerRadius: Corner radius of the continuous rounded rectangle. Defaults to 8.
    func settingsTintedGlassCard(
        color: Color,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(SettingsTintedGlassCard(
            backgroundColor: color.opacity(0.15),
            cornerRadius: cornerRadius
        ))
    }

    /// Applies the settings-local glass card with a final resolved background color.
    /// No additional opacity is applied — pass a token that already contains its opacity
    /// (e.g. `.rbGlassNeutralBackground`, `.rbAuthActiveGlassBackground`).
    ///
    /// - Parameters:
    ///   - background: Final resolved background color. Must not receive `.opacity(...)` at the call site.
    ///   - cornerRadius: Corner radius of the continuous rounded rectangle. Defaults to 8.
    func settingsGlassCard(
        background: Color,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(SettingsTintedGlassCard(
            backgroundColor: background,
            cornerRadius: cornerRadius
        ))
    }
}
