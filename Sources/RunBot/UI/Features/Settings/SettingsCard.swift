// SettingsCard.swift
// RunBot

import SwiftUI

// MARK: - Color token

/// Adaptive color extensions for settings surfaces.
extension Color {

    /// Adaptive card-background color for settings section cards.
    ///
    /// Dark:  6% white overlay — surface slightly lifted above the detail background.
    /// Light: 3.5% black overlay — surface slightly tinted below the light background.
    ///
    /// Opacity is applied only to the background shape; card content remains fully opaque.
    /// Borderless, shadowless, non-glass. (#2896)
    static let rbSettingsCardBackground = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedWhite: 1, alpha: 0.06)
                    : NSColor(calibratedWhite: 0, alpha: 0.035)
            }
        )
    )
}

// MARK: - SettingsCardModifier

/// Applies a soft, opaque filled card surface to any view.
///
/// ## Design rules
/// - Borderless: no stroke, shadow, or glass edge.
/// - Continuous 15-point corner radius.
/// - Internal padding of 18 points on all sides.
/// - Uses the `rbSettingsCardBackground` adaptive token.
///
/// Multi-row cards should add subtle internal `Divider`s (opacity 0.12)
/// between rows before applying this modifier.
private struct SettingsCardModifier: ViewModifier {
    /// Applies the card surface to the content.
    func body(content: Content) -> some View {
        content
            .padding(18)
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
    }
}

/// Settings card convenience extensions on `View`.
extension View {

    /// Wraps the receiver in a settings card surface.
    func settingsCard() -> some View {
        modifier(SettingsCardModifier())
    }
}
