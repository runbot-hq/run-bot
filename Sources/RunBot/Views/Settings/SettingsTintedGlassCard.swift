// SettingsTintedGlassCard.swift
// RunBot
import SwiftUI

// MARK: - SettingsTintedGlassCard

/// Settings-local Liquid Glass modifier that exactly mirrors the `DiskPillBadge`
/// and `StatusBadge` architecture used throughout RunBot.
///
/// Pattern (identical to proven badge implementation):
///
///     content
///         .background(color.opacity(0.15), in: shape)
///         .glassEffect(.regular, in: shape)
///
/// The base semantic color receives `opacity(0.15)` exactly once inside this
/// helper. Call sites must pass an undimmed semantic color (e.g. `.accentColor`,
/// `.rbDanger`). The native `.glassEffect(.regular)` generates all card-edge
/// highlights and refraction — no manual stroke is added.
///
/// ⚠️ Do NOT pass a pre-dimmed color (e.g. `color.opacity(0.07)`) at the call site.
/// ⚠️ Do NOT use `.regular.tint`. The opacity-0.15 background approach produces
/// visibly native glass; tinting a low-opacity color does not.
///
/// Scope: settings authentication and install/update cards only.
/// Do NOT move this to `DesignSystem` or use it outside Settings.
struct SettingsTintedGlassCard: ViewModifier {
    /// Base semantic color. `opacity(0.15)` is applied internally.
    let color: Color
    /// Corner radius for the continuous rounded-rectangle shape. Defaults to 8.
    let cornerRadius: CGFloat

    /// Applies the badge-pattern glass effect to the content.
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(color.opacity(0.15), in: shape)
            .glassEffect(.regular, in: shape)
    }
}

extension View {
    /// Applies the settings-local badge-pattern glass card.
    ///
    /// - Parameters:
    ///   - color: Base semantic color (undimmed). `opacity(0.15)` is applied internally.
    ///   - cornerRadius: Corner radius of the continuous rounded rectangle. Defaults to 8.
    func settingsTintedGlassCard(
        color: Color,
        cornerRadius: CGFloat = 8
    ) -> some View {
        modifier(SettingsTintedGlassCard(color: color, cornerRadius: cornerRadius))
    }
}
