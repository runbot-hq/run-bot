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

    // MARK: - redirectURI encoding contract (default + custom)

    /// Merges the former defaultRedirectURIIsEncodedCorrectly and
    /// customRedirectURIIsEncodedCorrectly tests into one loop-based contract.
    @Test("redirectURIs are serialised correctly for default and custom values")
    func redirectURIsAreEncodedCorrectly() throws {
        let cases: [(redirectURI: String?, expected: String)] = [
            // Default: omit redirectURI — should encode OAuthService.defaultRedirectURI.
            (nil, OAuthService.defaultRedirectURI),
            // Custom: explicit URI is forwarded verbatim.
            ("myapp-staging://oauth/callback", "myapp-staging://oauth/callback"),
        ]
        for testCase in cases {
            let service: OAuthService
            if let redirectURI = testCase.redirectURI {
                service = OAuthService(
                    clientID: "test-client-id",
                    clientSecret: "test-client-secret",
                    tokenStore: MockTokenStore(),
                    redirectURI: redirectURI
                )
            } else {
                service = OAuthService(
                    clientID: "test-client-id",
                    clientSecret: "test-client-secret",
                    tokenStore: MockTokenStore()
                )
            }
            let uri = try #require(redirectURIQueryItem(for: service))
            #expect(uri == testCase.expected, "redirectURI=\(String(describing: testCase.redirectURI))")
        }
    }
}
