// OAuthServiceAuthStateTests.swift
// OAuthTokenKitTests
//
// Exercises OAuthService.isAuthenticated via MockTokenStore.
//
// hasAnyToken env-var paths (GH_TOKEN, GITHUB_TOKEN) are covered in
// EnvTokenProviderTests and GitHubTokenCacheTests; the boolean returned by
// hasAnyToken when a store token is present is identical to isAuthenticated,
// so those variants are not duplicated here.
//
// Keychain is never touched: token store operations go through MockTokenStore,
// keeping this suite sandboxing-free and safe to run with `swift test`.
//
import Foundation
import Testing

@testable import OAuthTokenKit

@Suite("OAuthServiceAuthState", .serialized)
@MainActor
struct OAuthServiceAuthStateTests {

    private func makeService(storeToken: String? = nil) -> OAuthService {
        OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: MockTokenStore(initial: storeToken)
        )
    }

    // MARK: - isAuthenticated lifecycle

    /// Merges isAuthenticated_noToken_returnsFalse and
    /// isAuthenticated_withToken_returnsTrue into one lifecycle test.
    @Test func authenticationTracksTokenPresence() {
        #expect(makeService().isAuthenticated == false)
        #expect(makeService(storeToken: "oauth-token-xyz").isAuthenticated == true)
    }
}
