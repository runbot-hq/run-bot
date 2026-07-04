// GitHubTokenCache.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - Token cache
//
// githubToken() is called on every API request, often concurrently from multiple
// background threads. Without caching, each call reads from the keychain or the
// environment on every invocation, which adds unnecessary overhead.
//
// The actual caching and resolution logic lives in GitHubClient's injectable
// TokenCache (guarded by a Synchronization.Mutex). This file provides the
// unqualified githubToken() / invalidateTokenCache() free functions that
// production call-sites depend on, wiring the shared cache to the RunBot
// KeychainTokenStore instance.
//
// The cache is populated on first successful resolution and cleared by:
//   - OAuthService.signOut()  via invalidateTokenCache()
//   - OAuthService.save()     via invalidateTokenCache() (through tokenStore)

/// RunBot's keychain service name, matching the item stored by `KeychainTokenStore`.
private let keychainService = "run-bot"
/// RunBot's keychain account name, matching the item stored by `KeychainTokenStore`.
private let keychainAccount = "github-oauth-token"

/// Shared, process-wide token cache backing the free-function API below.
///
/// Resolution priority (unchanged from the pre-extraction implementation):
/// 1. In-memory cache
/// 2. Keychain (via `KeychainTokenStore`)
/// 3. `GH_TOKEN` environment variable
/// 4. `GITHUB_TOKEN` environment variable
private let sharedTokenCache = TokenCache(
    tokenStore: KeychainTokenStore(
        service: keychainService,
        account: keychainAccount,
        logger: RunBotLogger()
    ),
    logger: RunBotLogger()
)

// MARK: - Public API

/// Returns a GitHub personal access token from the first available source.
///
/// Priority order:
/// 1. In-memory cache — avoids repeated Keychain reads; invalidated on sign-in/sign-out.
/// 2. Keychain — OAuth token stored by OAuthService after the user signs in via the native flow.
/// 3. `GH_TOKEN` environment variable — useful in CI or scripted contexts.
/// 4. `GITHUB_TOKEN` environment variable — fallback for Actions-style environments.
///
/// Returns `nil` if no token is available from any source.
public func githubToken() -> String? {
    sharedTokenCache.token()
}

/// Clears the in-memory token cache. Call after saving a new token to Keychain
/// or after signing out so the next `githubToken()` call re-resolves from source.
///
/// ### Namespacing rationale
/// `invalidateTokenCache()` and `githubToken()` are intentionally free functions
/// rather than members of a namespace type. They are called as unqualified
/// symbols from `OAuthService` and SwiftUI views. Moving them into a namespace
/// type would require updating call-sites across multiple files for no
/// correctness benefit. The module boundary (`RunBotCore`) already provides
/// the necessary scoping.
public func invalidateTokenCache() {
    sharedTokenCache.invalidate()
}
