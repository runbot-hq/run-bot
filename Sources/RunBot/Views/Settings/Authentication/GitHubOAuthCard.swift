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
/// - Cancel / fail → previous source unchanged.
/// - Sign-out removes the credential but does **not** activate environment.
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
    /// Called when the user explicitly selects OAuth as the active source.
    let onSelect: () -> Void

    // MARK: - Derived

    /// `true` when `oauthState` is `.failed` — triggers red card styling.
    private var isError: Bool {
        if case .failed = oauthState { return true }
        return false
    }

    /// `true` while a sign-in or sign-out transition is in flight.
    private var isTransitioning: Bool {
        switch oauthState {
        case .signingIn, .signingOut: return true
        default: return false
        }
    }

    // MARK: - Body

    /// Card body: status dot, labels, inline error text, and action button.
    var body: some View {
        AuthenticationSourceCard(isActive: isActive, isError: isError) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    statusDot
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub OAuth")
                            .font(.system(size: 12, weight: .medium))
                        statusLine
                            .font(.caption)
                            .foregroundColor(statusLineColor)
                    }
                    .opacity(isActive ? 1.0 : 0.75)
                    Spacer()
                    actionButton
                        .opacity(isActive ? 1.0 : 0.65)
                }
                if case .failed(_, let message) = oauthState {
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(Color.rbDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(accessibilityValueText)
    }

    // MARK: - Sub-views

    /// Animated dot (or spinner) reflecting the current `oauthState`.
    @ViewBuilder
    private var statusDot: some View {
        switch oauthState {
        case .signingIn, .signingOut:
            ProgressView().scaleEffect(0.5).frame(width: 7, height: 7)
        case .signedOut:
            Circle().fill(Color.rbTextTertiary).frame(width: 7, height: 7)
        case .signedIn:
            Circle().fill(isActive ? Color.rbSuccess : Color.rbTextSecondary)
                .frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Color.rbDanger).frame(width: 7, height: 7)
        }
    }

    /// One-line status text below the title.
    private var statusLine: some View {
        Group {
            switch oauthState {
            case .signedOut:
                Text(isActive ? "Active · not authenticated" : "Not signed in")
            case .signingIn:
                Text("Waiting for browser…")
            case .signedIn(let username):
                if let username {
                    Text(isActive ? "Active · @\(username)" : "Signed in as @\(username) · inactive")
                } else {
                    Text(isActive ? "Active · authenticated" : "Authenticated · inactive")
                }
            case .signingOut(let username):
                Text("Signing out\(username.map { " @\($0)" } ?? "")…")
            case .failed:
                Text(isActive ? "Active · sign-in failed" : "Sign-in failed")
            }
        }
    }

    /// Status-line foreground color — red when failed, secondary otherwise.
    private var statusLineColor: Color {
        switch oauthState {
        case .failed: return Color.rbDanger
        default: return Color.rbTextSecondary
        }
    }

    /// Sign-in or Sign-out button, hidden during transitions.
    @ViewBuilder
    private var actionButton: some View {
        switch oauthState {
        case .signedOut, .failed:
            Button(action: onSignIn) {
                Text("Sign in with GitHub").font(.caption2)
            }
            .buttonStyle(.bordered)
            .disabled(isTransitioning || isSignInDisabled)
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
            .disabled(isTransitioning)
            .help("Remove OAuth token from Keychain")
        case .signingIn, .signingOut:
            EmptyView()
        }
    }

    /// VoiceOver value string combining source name, active state, and OAuth status.
    private var accessibilityValueText: String {
        let source = "GitHub OAuth"
        let activeText = isActive ? "active" : "inactive"
        switch oauthState {
        case .signedOut: return "\(source), \(activeText), signed out"
        case .signingIn: return "\(source), \(activeText), signing in"
        case .signedIn(let username): return "\(source), \(activeText), signed in\(username.map { " as @\($0)" } ?? "")"
        case .signingOut(let username): return "\(source), \(activeText), signing out\(username.map { " @\($0)" } ?? "")"
        case .failed(_, let message): return "\(source), \(activeText), failed: \(message)"
        }
    }
}
