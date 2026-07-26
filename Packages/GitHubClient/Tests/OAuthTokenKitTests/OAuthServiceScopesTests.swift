// OAuthServiceScopesTests.swift
// OAuthTokenKitTests

import Testing
import Foundation
@testable import OAuthTokenKit

// MARK: - OAuthServiceScopesTests

/// Tests for the configurable scopes API introduced in #44.
/// All tests use `MockTokenStore` to avoid Keychain access.
@Suite("OAuthService — configurable scopes")
@MainActor
struct OAuthServiceScopesTests {

    // MARK: - Helpers

    /// Extracts the `scope` query item value from the URL returned by `makeSignInURL()`.
    private func scopeQueryItem(for service: OAuthService) -> String? {
        guard let url = service.makeSignInURL(),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "scope" })?.value
    }

    // MARK: - Test 1: default scopes regression guard

    /// Verifies that an `OAuthService` created without an explicit `scopes`
    /// argument encodes all five default scopes in the correct order.
    ///
    /// Regression guard: if `OAuthService.defaultScopes` is ever accidentally
    /// modified, this test will catch it before it ships.
    @Test("default scopes produce the correct scope query item")
    func defaultScopesAreEncodedCorrectly() throws {
        let store = MockTokenStore()
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: store
            // scopes: omitted — should default to OAuthService.defaultScopes
        )
        let scope = try #require(scopeQueryItem(for: service))
        #expect(scope == "repo read:org admin:org manage_runners:org workflow")
    }

    // MARK: - Test 2: custom scopes encoding

    /// Verifies that a custom `scopes` array is serialised correctly into the
    /// `scope` query item as a single space-separated string.
    @Test("custom scopes are space-joined in the scope query item")
    func customScopesAreEncodedCorrectly() throws {
        let store = MockTokenStore()
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: store,
            scopes: [GitHubScopes.readUser, GitHubScopes.repo]
        )
        let scope = try #require(scopeQueryItem(for: service))
        #expect(scope == "read:user repo")
    }

    // MARK: - Test 3: empty scopes precondition (NOT executable in-process)

    /// The `precondition(!scopes.isEmpty)` in `OAuthService.init` cannot be
    /// tested in-process with Swift Testing — calling it would send SIGTRAP to
    /// the test runner, terminating the entire suite.
    ///
    /// To validate this guard, use one of:
    /// - A dedicated subprocess test (spawn a child process, assert non-zero exit).
    /// - An XCTest target with `XCTAssertPreconditionFailure` (e.g. via PointFree's
    ///   `XCTestDynamicOverlay` or a custom signal handler).
    ///
    /// The guard itself is documented and visible at:
    /// `Sources/OAuthTokenKit/OAuthService.swift` — `OAuthService.init`.
}
