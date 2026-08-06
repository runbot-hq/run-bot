// GitHubOAuthCard.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - GitHubOAuthCard

/// Settings card for the GitHub OAuth authentication source.
///
/// Displays the current `OAuthState` and provides sign-in / sign-out actions.
/// Interaction rules from #2459 §4.5:
///
/// - OAuth sign-in selects OAuth **only after success**, not when the browser opens.
/// - Sign-out removes the credential but does **not** activate environment.
///
/// ## Design
/// Only two states are represented: `.signedOut` and `.signedIn`. The browser
/// operation is not represented in application state — Keychain token presence
/// is the only truth.
struct GitHubOAuthCard: View {

    /// Current OAuth flow state.
    let oauthState: OAuthState
    /// Whether the OAuth source is the user's currently-selected source.
    let isActive: Bool
    /// When `true`, the Sign In button is disabled and dimmed.
    ///
    /// Set to `true` when the environment-token card is the active source so cards
    /// are mutually exclusive: the user must turn env off before signing in with OAuth.
    /// Sign-out is always enabled regardless of this flag.
    let isSignInDisabled: Bool
    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: () -> Void
    /// Called to sign out and remove the Keychain token.
    let onSignOut: () -> Void

    // MARK: - Body

    /// Card body: status dot, labels, and action button.
    var body: some View {
        AuthenticationSourceCard(isActive: isActive, isError: false) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        statusDot
                        Text("GitHub OAuth")
                            .font(.system(size: 12, weight: .medium))
                    }
                    statusLine
                        .font(.caption)
                        .foregroundColor(statusLineColor)
                }
                .opacity(isActive ? 1.0 : 0.75)
                Spacer()
                actionButton
                    .opacity(isActive ? 1.0 : 0.65)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValueText)
    }

    // MARK: - Sub-views

    /// Animated dot reflecting the current `oauthState`.
    @ViewBuilder
    private var statusDot: some View {
        switch oauthState {
        case .signedIn:
            Circle().fill(Color.rbSuccess)
                .frame(width: 7, height: 7)
        case .signedOut:
            Circle().fill(Color.rbTextTertiary).frame(width: 7, height: 7)
        }
    }

    /// One-line status text below the title.
    private var statusLine: some View {
        Group {
            switch oauthState {
            case .signedOut:
                Text("Not signed in to GitHub")
            case .signedIn(let username):
                if let username {
                    Text(isActive ? "Active · @\(username)" : "Signed in as @\(username) · inactive")
                } else {
                    Text(isActive ? "Active · authenticated" : "Authenticated · inactive")
                }
            }
        }
    }

    /// Status-line foreground color — secondary always (no error state).
    private var statusLineColor: Color {
        Color.rbTextSecondary
    }

    /// Sign-in or Sign-out button.
    @ViewBuilder
    private var actionButton: some View {
        switch oauthState {
        case .signedOut:
            Button(action: onSignIn) {
                Text("Sign in with GitHub").font(.caption2)
            }
            .buttonStyle(.bordered)
            .disabled(isSignInDisabled)
            .opacity(isSignInDisabled ? 0.4 : 1.0)
            .help(isSignInDisabled
                ? "Turn off Environment Token before signing in with OAuth"
                : "Authorize RunBot via GitHub OAuth and store token in Keychain"
            )
        case .signedIn:
            Button(action: onSignOut) {
                Text("Sign out").font(.caption2)
            }
            .buttonStyle(.bordered)
            .tint(Color.rbDanger)
            .help("Remove OAuth token from Keychain")
        }
    }

    /// VoiceOver value string combining source name, active state, and OAuth status.
    private var accessibilityValueText: String {
        let source = "GitHub OAuth"
        let activeText = isActive ? "active" : "inactive"
        switch oauthState {
        case .signedOut: return "\(source), \(activeText), signed out"
        case .signedIn(let username): return "\(source), \(activeText), signed in\(username.map { " as @\($0)" } ?? "")"
        }
    }
}
