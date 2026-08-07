// AuthenticationSourceCard.swift
// RunBot

import SwiftUI

// MARK: - AuthenticationSourceCard

/// Reusable card shell used by `EnvironmentTokenCard` and `GitHubOAuthCard`.
///
/// ## Design rules (from #2456 / #2508)
/// - Base semantic color at `opacity(0.15)` for active/error; `.clear` for neutral — mirrors `DiskPillBadge`.
/// - Native `.glassEffect(.regular)` produces edge highlights; no manual stroke overlay.
/// - Dim controls more than labels so stored state remains readable when inactive.
struct AuthenticationSourceCard<Content: View>: View {

    /// Whether this card represents the currently-active authentication source.
    let isActive: Bool
    /// Whether this card should display an error state (red border + fill).
    let isError: Bool
    /// Content of the card.
    @ViewBuilder let content: () -> Content

    /// Base semantic color for the glass card — undimmed, passed to `settingsTintedGlassCard`
    /// which applies `opacity(0.15)` internally (mirrors `DiskPillBadge`/`StatusBadge`).
    private var glassColor: Color {
        if isError { return .rbDanger }
        if isActive { return .accentColor }
        return .rbGlassNeutral
    }

    /// Card body: content wrapped in the badge-pattern Liquid Glass card.
    /// Edge highlights and refraction come exclusively from `.glassEffect(.regular)`.
    var body: some View {
        content()
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(10)
            .settingsTintedGlassCard(color: glassColor, cornerRadius: 8)
    }
}
