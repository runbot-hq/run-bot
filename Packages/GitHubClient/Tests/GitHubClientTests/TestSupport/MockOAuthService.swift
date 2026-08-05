// MockOAuthService.swift
// GitHubClientTests
//
// Spy/stub conforming to OAuthServiceProtocol for use in unit tests.
// All methods are no-ops by default; tests wire behaviour via the
// public mutation helpers (triggerSignIn, triggerSignOut).

import Foundation
import OAuthTokenKit
@testable import GitHubClient

// MARK: - MockOAuthService

/// A test double for `OAuthServiceProtocol`.
///
/// - Spy properties record every call for assertion.
/// - `triggerSignIn(_:)` / `triggerSignOut()` push events into
///   **all** live `AsyncStream` consumers (multicast).
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

    // MARK: - Private pending-state tracking

    /// Tracks whether a sign-in flow is pending (nonce has been generated).
    /// Mirrors the production `OAuthService.pendingState != nil` contract.
    private var isSignInPending = false

    // MARK: - Spy state

    private(set) var signOutCallCount = 0
    private(set) var cancelSignInCallCount = 0
    private(set) var handleCallbackURLs: [URL] = []
    private(set) var makeSignInURLCallCount = 0
    private(set) var makeSignInStreamCallCount = 0
    private(set) var makeSignOutStreamCallCount = 0

    /// Number of times a sign-in flow was started (makeSignInURL returned non-nil).
    private(set) var pendingSignInCount = 0

    // MARK: - Multicast stream continuations

    private var signInContinuations: [UUID: AsyncStream<Bool>.Continuation] = [:]
    private var signOutContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    // MARK: - OAuthServiceProtocol

    func makeSignInURL() -> URL? {
        makeSignInURLCallCount += 1
        if let url = signInURLToReturn {
            isSignInPending = true
            pendingSignInCount += 1
            return url
        }
        return nil
    }

    func signOut() {
        signOutCallCount += 1
        signOutContinuations.values.forEach { $0.yield(()) }
    }

    func handleCallback(_ url: URL) {
        handleCallbackURLs.append(url)
        // Clear pending state — the callback consumes the nonce.
        isSignInPending = false
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

    func makeSignOutStream() -> AsyncStream<Void> {
        makeSignOutStreamCallCount += 1
        let id = UUID()
        return AsyncStream { [weak self] continuation in
            self?.signOutContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.signOutContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func cancelSignIn() {
        cancelSignInCallCount += 1
        guard isSignInPending else {
            // No pending flow — no-op, matching production OAuthService contract.
            return
        }
        isSignInPending = false
        // Emit false to all active sign-in consumers.
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
