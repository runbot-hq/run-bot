// MigrationSettingsCard.swift
// RunBot

import SwiftUI

// MARK: - Color token

/// Adaptive color extensions for migration settings surfaces.
extension Color {

    /// Adaptive card-background color for migration settings section cards.
    ///
    /// Light: calibrated white 0.94 (subtly lighter than the window surface).
    /// Dark:  calibrated white 0.16 (subtly lighter than the dark column background).
    ///
    /// Using a dedicated adaptive token avoids the wash-out that `Color.primary.opacity(…)`
    /// produces when the system accent or vibrancy changes.
    static let rbSettingsCardBackground = Color(
        nsColor: NSColor(
            name: nil,
            dynamicProvider: { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return isDark
                    ? NSColor(calibratedWhite: 0.16, alpha: 1)
                    : NSColor(calibratedWhite: 0.94, alpha: 1)
            }
        )
    )
}

// MARK: - MigrationSettingsCardModifier

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
private struct MigrationSettingsCardModifier: ViewModifier {
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

/// Migration settings card convenience extensions on `View`.
extension View {

    /// Wraps the receiver in a migration settings card surface.
    func migrationSettingsCard() -> some View {
        modifier(MigrationSettingsCardModifier())
    }
}
