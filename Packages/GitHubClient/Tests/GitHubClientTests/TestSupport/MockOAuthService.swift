// MockOAuthService.swift
// GitHubClientTests
//
// Spy/stub conforming to OAuthServiceProtocol for use in unit tests.
// All methods are no-ops by default; tests wire behaviour via the
// public mutation helper (triggerSignIn).

import Foundation
import OAuthTokenKit
@testable import GitHubClient

// MARK: - MockOAuthService

/// A test double for `OAuthServiceProtocol`.
///
/// - Spy properties record every call for assertion.
/// - `triggerSignIn(_:)` pushes events into **all** live `AsyncStream` consumers (multicast).
///
/// ## Actor safety
/// Continuation dictionaries are `@MainActor`-isolated. Termination handlers
/// hop back to `@MainActor` via `Task { @MainActor … }` to avoid data races.
@MainActor
final class MockOAuthService: OAuthServiceProtocol {

    // MARK: - Controllable state

    var isAuthenticated: Bool = false
    var hasAnyToken: Bool = false
    var signInURLToReturn: URL?

    // MARK: - Spy state

    private(set) var signOutCallCount = 0
    private(set) var handleCallbackURLs: [URL] = []
    private(set) var makeSignInURLCallCount = 0
    private(set) var makeSignInStreamCallCount = 0

    // MARK: - Multicast stream continuations

    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]

    // MARK: - OAuthServiceProtocol

    func makeSignInURL() -> URL? {
        makeSignInURLCallCount += 1
        return signInURLToReturn
    }

    func signOut() {
        signOutCallCount += 1
    }

    func handleCallback(_ url: URL) {
        handleCallbackURLs.append(url)
    }

    func makeSignInStream() -> AsyncStream<Bool> {
        makeSignInStreamCallCount += 1
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.signInContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.signInContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    // MARK: - Test helpers

    /// Emits a sign-in result into **all** active `makeSignInStream()` consumers.
    func triggerSignIn(_ success: Bool) {
        signInContinuations.values.forEach { $0.yield(success) }
    }

    /// Number of active sign-in stream subscribers.
    var signInSubscriberCount: Int { signInContinuations.count }
}
