// OAuthState.swift
// GitHubClient

// MARK: - OAuthState

/// The current state of the OAuth authentication flow.
public enum OAuthState: Equatable, Sendable {
    /// No OAuth token is stored; the user is not signed in.
    case signedOut
    /// A sign-in flow is in progress (browser is open).
    case signingIn
    /// The user is signed in. `username` is `nil` until the identity fetch completes.
    case signedIn(username: String?)
    /// A sign-out is in progress.
    case signingOut(username: String?)
    /// A sign-in or sign-out operation failed.
    /// `previous` records the last stable state so the UI can restore it.
    case failed(previous: StableState, message: String)

    // MARK: - StableState

    /// A stable (non-transitional) OAuth state, used as the rollback target in `.failed`.
    public enum StableState: Equatable, Sendable {
        /// Was signed out before the failed operation.
        case signedOut
        /// Was signed in before the failed operation.
        case signedIn(username: String?)
    }
}
