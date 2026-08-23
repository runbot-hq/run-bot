// GitHubOAuthCard.swift
// RunBot

import GitHubClient
import SwiftUI

// MARK: - GitHubOAuthCard

/// Settings row for the GitHub OAuth authentication source.
///
/// Full-width row layout matching the standard settings card pattern (#2892).
/// The background fill comes from `AuthenticationSourceCard`.
///
/// Interaction rules from #2459 §4.5:
/// - OAuth sign-in selects OAuth **only after success**, not when the browser opens.
/// - Sign-out removes the credential but does **not** activate environment.
struct GitHubOAuthCard: View {

    /// Current OAuth flow state.
    let oauthState: OAuthState
    /// Whether the OAuth source is the user’s currently-selected source.
    let isActive: Bool
    /// When `true`, the Sign In button is disabled and dimmed.
    let isSignInDisabled: Bool
    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: () -> Void
    /// Called to sign out and remove the Keychain token.
    let onSignOut: () -> Void

    // MARK: - Body

    /// Full-width row: label block on the left, action button on the right.
    var body: some View {
        AuthenticationSourceCard(isActive: isActive, isError: false) {
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        statusDot
                        Text("GitHub OAuth")
                            .font(.system(size: 15, weight: .medium))
                            .lineLimit(1)
                    }
                    statusLine
                        .font(.system(size: 13))
                        .foregroundStyle(Color.rbTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .opacity(isActive ? 1.0 : 0.75)

                Spacer(minLength: 24)

                actionButton
                    .opacity(isActive ? 1.0 : 0.65)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValueText)
    }

    // MARK: - Sub-views

    /// Dot reflecting the current `oauthState`.
    @ViewBuilder
    private var statusDot: some View {
        switch oauthState {
        case .signedIn:
            Circle().fill(Color.rbSuccess).frame(width: 7, height: 7)
        case .signedOut:
            Circle().fill(Color.rbTextTertiary).frame(width: 7, height: 7)
        }
    }

    /// One-line status description below the title.
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

    /// Sign-in or Sign-out button, trailing-aligned.
    @ViewBuilder
    private var actionButton: some View {
        switch oauthState {
        case .signedOut:
            Button(action: onSignIn) {
                Text("Sign in").font(.system(size: 13))
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
                Text("Sign out").font(.system(size: 13))
            }
            .buttonStyle(.bordered)
            .tint(Color.rbDanger)
            .help("Remove OAuth token from Keychain")
        }
    }

    /// VoiceOver value string.
    private var accessibilityValueText: String {
        let source = "GitHub OAuth"
        let activeText = isActive ? "active" : "inactive"
        switch oauthState {
        case .signedOut: return "\(source), \(activeText), signed out"
        case .signedIn(let username): return "\(source), \(activeText), signed in\(username.map { " as @\($0)" } ?? "")"
        }
    }
}
