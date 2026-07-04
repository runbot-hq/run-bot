// MockOAuthService.swift
// GitHubClientTests
//
// Spy/stub conforming to OAuthServiceProtocol for use in unit tests.
// All methods are no-ops by default; tests wire behaviour via the
// public mutation helpers (triggerSignIn, triggerSignOut).

import Foundation
@testable import GitHubClient

// MARK: - MockOAuthService

/// A test double for `OAuthServiceProtocol`.
///
/// - Spy properties record every call for assertion.
/// - `triggerSignIn(_:)` / `triggerSignOut()` push events into
///   any live `AsyncStream` consumers.
@MainActor
final class MockOAuthService: OAuthServiceProtocol {

    // MARK: - Controllable state

    var isAuthenticated: Bool = false
    var hasAnyToken: Bool = false
    var signInURLToReturn: URL? = nil

    // MARK: - Spy state

    private(set) var signOutCallCount = 0
    private(set) var handleCallbackURLs: [URL] = []
    private(set) var makeSignInURLCallCount = 0

    // MARK: - Stream continuations

    private var signInContinuation: AsyncStream<Bool>.Continuation?
    private var signOutContinuation: AsyncStream<Void>.Continuation?

    // MARK: - OAuthServiceProtocol

    func makeSignInURL() -> URL? {
        makeSignInURLCallCount += 1
        return signInURLToReturn
    }

    func signOut() {
        signOutCallCount += 1
        signOutContinuation?.yield(())
    }

    func handleCallback(_ url: URL) {
        handleCallbackURLs.append(url)
    }

    func makeSignInStream() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            self.signInContinuation = continuation
        }
    }

    func makeSignOutStream() -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.signOutContinuation = continuation
        }
    }

    // MARK: - Test helpers

    /// Emits a sign-in result into any active `makeSignInStream()` consumer.
    func triggerSignIn(_ success: Bool) {
        signInContinuation?.yield(success)
    }

    /// Emits a sign-out event into any active `makeSignOutStream()` consumer.
    func triggerSignOut() {
        signOutContinuation?.yield(())
    }
}
