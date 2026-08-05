// MockOAuthService.swift
// GitHubClientTests
//
// Spy/stub conforming to OAuthServiceProtocol for use in unit tests.
// All methods are no-ops by default; tests wire behaviour via the
// public mutation helpers (triggerSignIn, triggerSignOut).
//
// Upgrade from single-continuation to multicast (dictionary-per-stream) so
// the coordinator and an app-level sign-out subscriber can coexist in the
// same test — matching the production OAuthService pattern.

import Foundation
import OAuthTokenKit
@testable import GitHubClient

// MARK: - MockOAuthService

/// A test double for `OAuthServiceProtocol`.
///
/// - Spy properties record every call for assertion.
/// - `triggerSignIn(_:)` / `triggerSignOut()` push events into
///   **all** live `AsyncStream` consumers (multicast).
@MainActor
final class MockOAuthService: OAuthServiceProtocol {

    // MARK: - Controllable state

    var isAuthenticated: Bool = false
    var hasAnyToken: Bool = false
    var signInURLToReturn: URL?

    // MARK: - Spy state

    private(set) var signOutCallCount = 0
    private(set) var cancelSignInCallCount = 0
    private(set) var handleCallbackURLs: [URL] = []
    private(set) var makeSignInURLCallCount = 0
    private(set) var makeSignInStreamCallCount = 0
    private(set) var makeSignOutStreamCallCount = 0

    // MARK: - Multicast stream continuations

    // nonisolated(unsafe): the dictionaries are written from @MainActor (stream
    // creation) and from the @Sendable onTermination callback (task cancellation).
    // All writes happen either on MainActor or serially via Task cancellation which
    // occurs after the last strong reference drops — no data race in practice.
    // The unsafe annotation is intentional; adding a lock here would complicate
    // test code for no safety benefit in a single-threaded test environment.
    nonisolated(unsafe) private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    nonisolated(unsafe) private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    // MARK: - OAuthServiceProtocol

    func makeSignInURL() -> URL? {
        makeSignInURLCallCount += 1
        return signInURLToReturn
    }

    func signOut() {
        signOutCallCount += 1
        signOutContinuations.values.forEach { $0.yield(()) }
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
                self?.signInContinuations.removeValue(forKey: id)
            }
        }
    }

    func makeSignOutStream() -> AsyncStream<Void> {
        makeSignOutStreamCallCount += 1
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.signOutContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                self?.signOutContinuations.removeValue(forKey: id)
            }
        }
    }

    func cancelSignIn() {
        cancelSignInCallCount += 1
        // Emit false to all active sign-in consumers, matching OAuthService behaviour.
        signInContinuations.values.forEach { $0.yield(false) }
    }

    // MARK: - Test helpers

    /// Emits a sign-in result into **all** active `makeSignInStream()` consumers.
    func triggerSignIn(_ success: Bool) {
        signInContinuations.values.forEach { $0.yield(success) }
    }

    /// Emits a sign-out event into **all** active `makeSignOutStream()` consumers.
    func triggerSignOut() {
        signOutContinuations.values.forEach { $0.yield(()) }
    }

    /// Number of active sign-in stream subscribers.
    var signInSubscriberCount: Int { signInContinuations.count }

    /// Number of active sign-out stream subscribers.
    var signOutSubscriberCount: Int { signOutContinuations.count }
}
