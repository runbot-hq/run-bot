// OAuthCredentialController.swift
// GitHubClient

import Foundation
import OAuthTokenKit

// MARK: - OAuthCredentialController

/// Narrow credential controller that owns exactly one app-lifetime sign-in observation.
///
/// Replaces `OAuthSessionCoordinator`. The browser operation is not represented in
/// application state — only Keychain token presence matters.
///
/// ## Design
/// - One task: observes `makeSignInStream()` for the lifetime of the app.
/// - No sign-out stream. Sign-out is synchronous and direct.
/// - No transition policy, rollback, cancellation, or attempt correlation.
/// - `reconcile()` handles external Keychain changes and stale Settings UI.
///
/// ## Task lifetime
/// `signInTask` is cancelled when the controller deallocates, releasing the
/// stream subscription cleanly.
@MainActor
public final class OAuthCredentialController {
    /// The OAuth service used to create sign-in URLs, manage the sign-in stream, and sign out.
    private let service: any OAuthServiceProtocol
    /// The shared authentication state model updated on sign-in / sign-out / reconcile.
    private let authentication: GitHubAuthentication

    /// The long-lived sign-in stream observation task. Cancelled in `deinit`.
    nonisolated(unsafe)
    private var signInTask: Task<Void, Never>?

    /// Creates a new credential controller.
    ///
    /// - Parameters:
    ///   - service: The OAuth service to use for sign-in URL creation, stream registration, and sign-out.
    ///   - authentication: The shared authentication state model to update on credential changes.
    public init(
        service: any OAuthServiceProtocol,
        authentication: GitHubAuthentication
    ) {
        self.service = service
        self.authentication = authentication
    }

    deinit {
        signInTask?.cancel()
    }

    // MARK: - Lifecycle

    /// Registers the sign-in stream and starts the observation task. Idempotent.
    ///
    /// Call before the first suspension point so no browser callback can be missed.
    /// The stream is registered synchronously before the Task is created so an
    /// early callback arriving before the first await is buffered by `AsyncStream`.
    public func start() {
        guard signInTask == nil else { return }

        let stream = service.makeSignInStream()
        let authentication = authentication

        signInTask = Task { @MainActor in
            for await success in stream {
                guard !Task.isCancelled else { return }
                guard success else { continue }
                authentication.recordOAuthSignIn(username: nil)
            }
        }
    }

    // MARK: - Actions

    /// Returns the OAuth authorization URL, or `nil` if the URL cannot be built.
    ///
    /// Each call generates a fresh nonce; a subsequent call replaces the pending nonce.
    /// The caller is responsible for opening the URL in the system browser.
    public func makeSignInURL() -> URL? {
        service.makeSignInURL()
    }

    /// Reconciles `GitHubAuthentication` against live Keychain state.
    ///
    /// Call on Settings `.onAppear` to handle external Keychain changes and stale UI.
    /// Safe to call at any time — no transitional state is affected.
    public func reconcile() {
        authentication.syncOAuthState(isAuthenticated: service.isAuthenticated)
    }

    /// Synchronously deletes the Keychain token and reconciles authentication state.
    ///
    /// The UI changes to Sign in as soon as `service.signOut()` returns because
    /// `syncOAuthState` immediately reflects token absence. App-specific follow-up
    /// (e.g. runner-poll restart) belongs to the caller, not this controller.
    public func signOut() {
        service.signOut()
        authentication.syncOAuthState(isAuthenticated: service.isAuthenticated)
    }
}
