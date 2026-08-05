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
    private let service: any OAuthServiceProtocol
    private let authentication: GitHubAuthentication
    private let didSignOut: @MainActor () async -> Void

    nonisolated(unsafe)
    private var signInTask: Task<Void, Never>?

    public init(
        service: any OAuthServiceProtocol,
        authentication: GitHubAuthentication,
        didSignOut: @escaping @MainActor () async -> Void = {}
    ) {
        self.service = service
        self.authentication = authentication
        self.didSignOut = didSignOut
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

    /// Synchronously deletes the Keychain token, reconciles authentication state,
    /// then invokes the `didSignOut` callback (e.g. restart runner polling).
    ///
    /// The UI changes to Sign in as soon as `service.signOut()` returns because
    /// `syncOAuthState` immediately reflects token absence.
    public func signOut() async {
        service.signOut()
        authentication.syncOAuthState(isAuthenticated: service.isAuthenticated)
        await didSignOut()
    }
}
