// OAuthState.swift
// GitHubClient

// MARK: - OAuthState

/// Stable credential state for the GitHub OAuth flow.
///
/// Keychain token presence is the only truth. There are no transitional states —
/// browser progress is not represented in application state.
public enum OAuthState: Equatable, Sendable {
    /// No OAuth token is present in Keychain; the user is signed out.
    case signedOut
    /// An OAuth token is present in Keychain.
    /// `username` is `nil` until the identity fetch completes.
    case signedIn(username: String?)
}
