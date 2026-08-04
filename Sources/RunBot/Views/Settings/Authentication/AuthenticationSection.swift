// AuthenticationSection.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - AuthenticationSection

/// Two-card authentication section for the Settings view.
///
/// Replaces the single-branch `accountSection` in `SettingsView+Sections.swift`.
/// Reads `GitHubAuthentication` state directly and fires action callbacks so the
/// parent (`SettingsView`) keeps ownership of service calls.
///
/// ## Layout (from #2456 / #2459 §4.3)
/// Both cards sit inside one "Account" section.
/// Environment card is on the left; OAuth card is on the right.
struct AuthenticationSection: View {

    /// The shared authentication state model. Read-only in this view.
    let authentication: GitHubAuthentication
    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: () -> Void
    /// Called to sign out and remove the stored OAuth token.
    let onSignOut: () -> Void
    /// Called when the user selects a specific source explicitly.
    let onSelectSource: (GitHubAuthSource) -> Void
    /// Called when the environment toggle is flipped. `true` = activate env source.
    let onToggleEnvironment: (Bool) -> Void

    // MARK: - Body

    /// Two-card layout: environment token card on the left, OAuth card on the right.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account")
                .font(RBFont.sectionHeader)
                .foregroundColor(Color.rbTextSecondary)
                .padding(.horizontal, RBSpacing.md)
                .padding(.top, 8)
                .padding(.bottom, 4)

            HStack(alignment: .top, spacing: 8) {
                EnvironmentTokenCard(
                    envState: authentication.environmentState,
                    isActive: authentication.selectedSource == .environment,
                    onToggle: onToggleEnvironment
                )

                GitHubOAuthCard(
                    oauthState: authentication.oauthState,
                    isActive: authentication.selectedSource == .oauth,
                    onSignIn: onSignIn,
                    onSignOut: onSignOut,
                    onSelect: { onSelectSource(.oauth) }
                )
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
        }
    }
}
