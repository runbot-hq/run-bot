// OAuthServiceRedirectURITests.swift
// OAuthTokenKitTests

import Testing
import Foundation
@testable import OAuthTokenKit

// MARK: - OAuthServiceRedirectURITests

/// Tests for the configurable redirectURI API introduced in #46.
/// Mirrors the structure of `OAuthServiceScopesTests` from #44.
/// All tests use `MockTokenStore` to avoid Keychain access.
@Suite("OAuthService — configurable redirectURI")
@MainActor
struct OAuthServiceRedirectURITests {

    // MARK: - Helpers

    /// Extracts the `redirect_uri` query item value from the URL returned by `makeSignInURL()`.
    private func redirectURIQueryItem(for service: OAuthService) -> String? {
        guard let url = service.makeSignInURL(),
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value
    }

    // MARK: - Test 1: default redirectURI regression guard

    /// Verifies that an `OAuthService` created without an explicit `redirectURI`
    /// argument encodes `OAuthService.defaultRedirectURI` in the authorize URL.
    ///
    /// Regression guard: if `GitHubConstants.oauthRedirectURI` is ever accidentally
    /// changed, this test will catch the drift.
    @Test("default redirectURI is encoded as redirect_uri query item")
    func defaultRedirectURIIsEncodedCorrectly() throws {
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: MockTokenStore()
            // redirectURI: omitted — should default to OAuthService.defaultRedirectURI
        )
        let uri = try #require(redirectURIQueryItem(for: service))
        #expect(uri == OAuthService.defaultRedirectURI)
    }

    // MARK: - Test 2: custom redirectURI encoding

    /// Verifies that a custom `redirectURI` string passed at init time is
    /// serialised correctly into the `redirect_uri` query item.
    @Test("custom redirectURI appears as redirect_uri query item")
    func customRedirectURIIsEncodedCorrectly() throws {
        let service = OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: MockTokenStore(),
            redirectURI: "myapp-staging://oauth/callback"
        )
        let uri = try #require(redirectURIQueryItem(for: service))
        #expect(uri == "myapp-staging://oauth/callback")
    }
}
