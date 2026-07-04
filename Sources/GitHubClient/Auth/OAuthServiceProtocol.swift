// OAuthServiceProtocol.swift
// GitHubClient
import Foundation

// MARK: - OAuthServiceProtocol

/// Abstraction over the GitHub OAuth Authorization Code flow.
///
/// `@MainActor` isolation mirrors the concrete `OAuthService` — all methods are
/// serialised on the main thread because:
/// - `handleCallback(_:)` is delivered by `AppDelegate.application(_:open:)` on the main thread.
/// - `makeSignInStream()` is consumed by SwiftUI views (`SettingsView`).
/// - `makeSignOutStream()` is consumed by `AppDelegate.setupSignOutSubscription()`,
///   which runs on `@MainActor`.
///
/// `AnyObject` constraint is required because the protocol has settable state.
/// Mutating stored properties requires reference semantics — structs cannot adopt this protocol.
///
/// ## Production usage
/// ```swift
/// let oauthService: any OAuthServiceProtocol = OAuthService()
/// ```
///
/// ## Test double
/// ```swift
/// @MainActor
/// final class StubOAuthService: OAuthServiceProtocol {
///     func makeSignInURL() -> URL? { nil }
///     func signOut() {}
///     func handleCallback(_ url: URL) {}
///     func makeSignInStream() -> AsyncStream<Bool> { AsyncStream { _ in } }
///     func makeSignOutStream() -> AsyncStream<Void> { AsyncStream { _ in } }
/// }
/// ```
@MainActor
public protocol OAuthServiceProtocol: AnyObject {
    /// Builds and returns the GitHub OAuth authorization URL, storing the CSRF nonce.
    /// The caller is responsible for opening the URL (e.g. `NSWorkspace.shared.open(url)`).
    /// Returns `nil` if the URL cannot be constructed.
    func makeSignInURL() -> URL?

    /// Clears the stored token and emits a sign-out event to all stream consumers.
    func signOut()

    /// Handles the OAuth redirect URL from the OS, verifying the CSRF state nonce
    /// and exchanging the authorization code for an access token.
    func handleCallback(_ url: URL)

    /// Returns a new `AsyncStream<Bool>` that fires once per sign-in attempt.
    /// `true` = success, `false` = failure.
    func makeSignInStream() -> AsyncStream<Bool>

    /// Returns a new `AsyncStream<Void>` that fires once per `signOut()` call.
    /// Each call site must request its own stream; events are multicasted across all active streams.
    func makeSignOutStream() -> AsyncStream<Void>
}
