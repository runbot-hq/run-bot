// AuthenticationSourceCard.swift
// RunBot

import SwiftUI

// MARK: - AuthenticationSourceCard

/// Reusable card shell used by `EnvironmentTokenCard` and `GitHubOAuthCard`.
///
/// ## Design rules (from #2456 / #2508)
/// - Final resolved background tokens carry embedded opacity (`rbAuthActiveGlassBackground`, `rbGlassNeutralBackground`, `rbDanger.opacity(0.15)`).
/// - Native `.glassEffect(.regular)` produces edge highlights; no manual stroke overlay.
/// - Dim controls more than labels so stored state remains readable when inactive.
struct AuthenticationSourceCard<Content: View>: View {

    /// Whether this card represents the currently-active authentication source.
    let isActive: Bool
    /// Whether this card should display an error state (red border + fill).
    let isError: Bool
    /// Content of the card.
    @ViewBuilder let content: () -> Content

    /// Final resolved background color for the glass card.
    /// Each value already contains its opacity — do NOT append `.opacity(...)` at the call site.
    /// Mapping:
    /// - Error  → `rbDanger` at 0.15 (red; strength matches pre-existing error cards).
    /// - Active → `rbAuthActiveGlassBackground` (green 0.22 light / 0.15 dark).
    /// - Inactive → `rbAuthInactiveGlassBackground` (black 0.08 light / white 0.07 dark).
    private var glassBackground: Color {
        if isError { return Color.rbDanger.opacity(0.15) }
        if isActive { return .rbAuthActiveGlassBackground }
        return .rbAuthInactiveGlassBackground
    }

    /// Card body: content with a flat state-colour fill.
    /// The parent group in `AuthenticationSection` owns the outer clip shape.
    var body: some View {
        content()
            .background(glassBackground)
    }
}
