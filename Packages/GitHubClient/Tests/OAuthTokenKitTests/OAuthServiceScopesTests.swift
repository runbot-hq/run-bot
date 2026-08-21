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

    // MARK: - Scope encoding contract (default + custom)

    /// Merges the former defaultScopesAreEncodedCorrectly and
    /// customScopesAreEncodedCorrectly tests into one loop-based contract.
    @Test("scopes are encoded correctly for default and custom configurations")
    func scopesAreEncodedCorrectly() throws {
        let cases: [(scopes: [String]?, expected: String)] = [
            // Default: omit scopes argument — should encode OAuthService.defaultScopes.
            (nil, "repo read:org admin:org manage_runners:org workflow"),
            // Custom: explicit scope list serialised as space-separated string.
            ([GitHubScopes.readUser, GitHubScopes.repo], "read:user repo"),
        ]
        for testCase in cases {
            let store = MockTokenStore()
            let service: OAuthService
            if let scopes = testCase.scopes {
                service = OAuthService(
                    clientID: "test-client-id",
                    clientSecret: "test-client-secret",
                    tokenStore: store,
                    scopes: scopes
                )
            } else {
                service = OAuthService(
                    clientID: "test-client-id",
                    clientSecret: "test-client-secret",
                    tokenStore: store
                )
            }
            let scope = try #require(scopeQueryItem(for: service))
            #expect(scope == testCase.expected, "scopes=\(String(describing: testCase.scopes))")
        }
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
