// AuthenticationSourceCard.swift
// RunBot

import SwiftUI

// MARK: - AuthenticationSourceCard

/// Reusable card shell used by `EnvironmentTokenCard` and `GitHubOAuthCard`.
///
/// ## Design rules (from #2456)
/// - Low-opacity accent fill only for the **active or erroneous** card; neutral stroke otherwise.
/// - Dim controls more than labels so stored state remains readable when inactive.
struct AuthenticationSourceCard<Content: View>: View {

    /// Whether this card represents the currently-active authentication source.
    let isActive: Bool
    /// Whether this card should display an error state (red border + fill).
    let isError: Bool
    /// Content of the card.
    @ViewBuilder let content: () -> Content

    /// Border color — accent when active, danger when error, neutral otherwise.
    private var strokeColor: Color {
        if isError { return Color.rbDanger.opacity(0.6) }
        if isActive { return Color.accentColor.opacity(0.6) }
        return Color.rbBorderSubtle
    }

    /// Background fill — low-opacity accent/danger when prominent, transparent otherwise.
    private var fillColor: Color {
        if isError { return Color.rbDanger.opacity(0.07) }
        if isActive { return Color.accentColor.opacity(0.07) }
        return Color.clear
    }

    /// Card body: content wrapped in a tint-aware Liquid Glass card + stroke overlay.
    var body: some View {
        content()
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(10)
            .glassCard(cornerRadius: 8, tint: fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }
}
