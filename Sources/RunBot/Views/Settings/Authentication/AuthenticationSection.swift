// AuthenticationSection.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - AuthenticationSection

/// Two-row authentication section for the Settings view.
///
/// Replaces the single-branch `accountSection` in `SettingsView+Sections.swift`.
/// Reads `GitHubAuthentication` state directly and fires action callbacks so the
/// parent (`SettingsView`) keeps ownership of service calls.
///
/// ## Layout (from #2892)
/// Both cards stack vertically as full-width rows so titles never wrap.
/// Each card owns its own background fill; no outer GlassEffectContainer.
struct AuthenticationSection: View {

    /// The shared authentication state model. Read-only in this view.
    let authentication: GitHubAuthentication
    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: () -> Void
    /// Called to sign out and remove the stored OAuth token.
    let onSignOut: () -> Void
    /// Called when the environment toggle is flipped. `true` = activate env source.
    let onToggleEnvironment: (Bool) -> Void

    // MARK: - Derived

    /// `true` when environment token is the active source.
    private var envIsActive: Bool { authentication.selectedSource == .environment }

    /// `true` when OAuth is the active source.
    private var oauthIsActive: Bool {
        if case .signedIn = authentication.oauthState { return true }
        return false
    }

    /// `true` while an OAuth credential is present (signed in).
    private var oauthBlocksEnvironment: Bool {
        if case .signedIn = authentication.oauthState { return true }
        return false
    }

    /// `true` when an environment token has been discovered.
    private var environmentIsAvailable: Bool {
        if case .available = authentication.environmentState { return true }
        return false
    }

    /// `true` when the environment toggle should be disabled.
    ///
    /// `envIsActive` is checked first so the user can always turn Environment off.
    /// REVIEWERS: Do not remove the availability gate.
    private var environmentToggleDisabled: Bool {
        if envIsActive { return false }
        return oauthBlocksEnvironment || !environmentIsAvailable
    }

    // MARK: - Body

    /// Group heading + two full-width source rows stacked vertically.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Authentication")
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 12) {
                EnvironmentTokenCard(
                    envState: authentication.environmentState,
                    isActive: envIsActive,
                    isDisabled: environmentToggleDisabled,
                    onToggle: onToggleEnvironment
                )
                .frame(maxWidth: .infinity)

                GitHubOAuthCard(
                    oauthState: authentication.oauthState,
                    isActive: oauthIsActive,
                    isSignInDisabled: envIsActive,
                    onSignIn: onSignIn,
                    onSignOut: onSignOut
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}
