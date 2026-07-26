// OAuthServiceAuthStateTests.swift
// OAuthTokenKitTests
//
// Exercises `OAuthService.isAuthenticated` and `OAuthService.hasAnyToken`.
//
// ⚠️ ISOLATION REQUIREMENT
// `hasAnyToken` reads the live process environment via `getenv()` (through the
// private `envVarIsSet(_:)` helper in `OAuthService`), NOT via
// `ProcessInfo.processInfo.environment`. `setenv`/`unsetenv` mutate the
// process-global environment, so this suite is `.serialized` and every env-var
// test wraps its body in `withCleanEnv`.
//
// Note: `@MainActor` already serialises this suite on the main actor (the main
// actor is a serial executor), so `.serialized` is belt-and-suspenders here
// rather than a strict correctness requirement. It is retained because the
// suite's env-var mutation pattern is fragile enough that the redundancy is
// worthwhile — and because removing `.serialized` would be invisible to future
// authors who don't know this suite is @MainActor-isolated.
//
// Why getenv() and not ProcessInfo?
// `ProcessInfo.processInfo.environment` is a snapshot captured at process launch;
// `setenv`/`unsetenv` mutations are invisible to it within the same process.
// `getenv()` always reflects the current state of the POSIX environment, which
// is why `OAuthService.envVarIsSet(_:)` uses it and why the test helpers here
// also use `getenv()` for save/restore.
//
// Keychain is never touched: token store operations are exercised through a
// `MockTokenStore`, keeping these tests sandboxing-free and safe to run with
// `swift test`.

import Foundation
import Testing

@testable import OAuthTokenKit

// MARK: - Helpers

/// Strips both token env vars, runs body, then restores the previous values.
///
/// Uses `getenv()` (not `ProcessInfo.processInfo.environment`) for save/restore
/// because `ProcessInfo` captures a snapshot at process start and does not
/// reflect live `setenv`/`unsetenv` mutations. `getenv()` always reflects the
/// current state of the process environment.
///
/// Note: the `.serialized` attribute on `OAuthServiceAuthStateTests` and the
/// `@MainActor` isolation together ensure no two tests in this suite run
/// concurrently. `withCleanEnv` relies on that guarantee — do not call it
/// from a non-serialized or non-`@MainActor` context without adding your own
/// synchronisation.
///
/// The signature is `async` for consistency with the equivalent helpers in
/// `EnvTokenProviderTests` and `GitHubTokenCacheTests`, and to avoid a latent
/// trap where adding an `await` inside `body` would silently fail to compile
/// against a synchronous closure parameter.
private func withCleanEnv(_ body: () async -> Void) async {
    let prevGH = getenv("GH_TOKEN").flatMap { String(cString: $0) }
    let prevGitHub = getenv("GITHUB_TOKEN").flatMap { String(cString: $0) }
    unsetenv("GH_TOKEN")
    unsetenv("GITHUB_TOKEN")
    await body()
    if let prevGH { setenv("GH_TOKEN", prevGH, 1) } else { unsetenv("GH_TOKEN") }
    if let prevGitHub { setenv("GITHUB_TOKEN", prevGitHub, 1) } else { unsetenv("GITHUB_TOKEN") }
}

// MARK: - OAuthServiceAuthStateTests

@Suite("OAuthServiceAuthState", .serialized)
// @MainActor is load-bearing: OAuthService is @MainActor-isolated, so its
// properties (isAuthenticated, hasAnyToken) can only be accessed synchronously
// from a @MainActor context. Removing this attribute causes actor-isolation
// compiler errors at every property access in the test bodies below.
//
// Serialisation note: @MainActor already serialises all tests in this suite on
// the main actor (a serial executor). The .serialized trait above is
// belt-and-suspenders — see the file-level comment for the full rationale.
@MainActor
struct OAuthServiceAuthStateTests {

    /// Builds an `OAuthService` backed by an (optionally seeded) `MockTokenStore`.
    private func makeService(storeToken: String? = nil) -> OAuthService {
        OAuthService(
            clientID: "test-client-id",
            clientSecret: "test-client-secret",
            tokenStore: MockTokenStore(initial: storeToken)
        )
    }

    // MARK: - isAuthenticated

    /// `isAuthenticated` is `false` when the token store is empty.
    @Test func isAuthenticated_noToken_returnsFalse() {
        let service = makeService()
        #expect(service.isAuthenticated == false)
    }

    /// `isAuthenticated` is `true` when the token store holds a valid token.
    @Test func isAuthenticated_withToken_returnsTrue() {
        let service = makeService(storeToken: "oauth-token-xyz")
        #expect(service.isAuthenticated == true)
    }

    // MARK: - hasAnyToken

    /// `hasAnyToken` is `false` when the store is empty and no env var is set.
    @Test func hasAnyToken_noSource_returnsFalse() async {
        await withCleanEnv {
            let service = makeService()
            #expect(service.hasAnyToken == false)
        }
    }

    /// `hasAnyToken` is `true` when `isAuthenticated` is true (store has a token),
    /// even with no env var set.
    @Test func hasAnyToken_oauthToken_returnsTrue() async {
        await withCleanEnv {
            let service = makeService(storeToken: "oauth-token")
            #expect(service.hasAnyToken == true)
        }
    }

    /// `hasAnyToken` is `true` when `GH_TOKEN` is set in the environment,
    /// even when the token store is empty (`isAuthenticated == false`).
    ///
    /// This is the env-var fallback path described in `OAuthService.hasAnyToken`.
    /// It is exercised by the CI runner via the `GH_TOKEN: test-ci-token` env
    /// var injected in `.github/workflows/swift-test.yml`.
    @Test func oauthService_hasAnyToken_envVarFallback() async {
        await withCleanEnv {
            setenv("GH_TOKEN", "test-ci-token", 1)
            let service = makeService()  // empty store — isAuthenticated == false
            // GH_TOKEN is set → hasAnyToken must return true via the env-var branch.
            #expect(service.hasAnyToken == true)
        }
    }

    /// `hasAnyToken` is `true` when `GITHUB_TOKEN` is set and `GH_TOKEN` is absent.
    @Test func hasAnyToken_githubTokenEnvVar_returnsTrue() async {
        await withCleanEnv {
            setenv("GITHUB_TOKEN", "github-env-token", 1)
            let service = makeService()
            #expect(service.hasAnyToken == true)
        }
    }
}
