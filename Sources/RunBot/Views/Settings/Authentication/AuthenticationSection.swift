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
    /// Called when the environment toggle is flipped. `true` = activate env source.
    let onToggleEnvironment: (Bool) -> Void

    // MARK: - Derived

    /// `true` when environment token is the active source.
    /// The OAuth sign-in button is disabled while env is active.
    private var envIsActive: Bool { authentication.selectedSource == .environment }

    /// `true` when OAuth is the active source.
    /// Derived from `oauthState` rather than `selectedSource` so the card
    /// reflects the actual authentication state, not a persisted preference.
    private var oauthIsActive: Bool {
        switch authentication.oauthState {
        case .signedIn, .signingOut:
            return true
        case .signedOut, .signingIn, .failed:
            return false
        }
    }

    /// `true` while an OAuth operation is in progress or authenticated.
    /// The environment toggle is disabled so the user cannot switch away
    /// during an active flow or while OAuth credentials are present.
    private var oauthBlocksEnvironment: Bool {
        switch authentication.oauthState {
        case .signingIn, .signedIn, .signingOut:
            return true
        case .signedOut, .failed:
            return false
        }
    }

    /// `true` when an environment token has been discovered.
    private var environmentIsAvailable: Bool {
        if case .available = authentication.environmentState {
            return true
        }
        return false
    }

    /// `true` when the environment toggle should be disabled.
    ///
    /// Always allows the user to turn Environment mode **off** (even if the
    /// token has since disappeared). The toggle is disabled when:
    /// - Environment is not active AND OAuth is blocking, OR
    /// - Environment is not active AND no environment token is available
    ///   (including while discovery is still checking).
    private var environmentToggleDisabled: Bool {
        if envIsActive {
            // Always allow the user to turn Environment mode off.
            return false
        }
        return oauthBlocksEnvironment || !environmentIsAvailable
    }

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
                // Env card: disabled when the environment toggle should be disabled
                // (env not active and either OAuth is blocking or no env token is available).
                // Always allows turning off if env is already active.
                EnvironmentTokenCard(
                    envState: authentication.environmentState,
                    isActive: envIsActive,
                    isDisabled: environmentToggleDisabled,
                    onToggle: onToggleEnvironment
                )

                // OAuth card: sign-in button disabled while env is the active source.
                // The user must turn env off before signing in with OAuth so the transition
                // is always explicit. Sign-out is always available regardless of source.
                GitHubOAuthCard(
                    oauthState: authentication.oauthState,
                    isActive: oauthIsActive,
                    isSignInDisabled: envIsActive,
                    onSignIn: onSignIn,
                    onSignOut: onSignOut
                )
            }
            .padding(.horizontal, RBSpacing.md)
            .padding(.vertical, 8)
        }
    }
}
