// GitHubTokenCache.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - Token cache
//
// githubToken() is called on every API request, often concurrently from multiple
// background threads. Without caching, each call reads from Keychain or the
// environment on every invocation, which adds unnecessary overhead.
//
// The actual caching and resolution logic lives in GitHubClient's injectable
// `TokenCache` (guarded by a Synchronization.Mutex). This file provides the
// unqualified `githubToken()` / `invalidateTokenCache()` free functions that
// production call-sites (Keychain.swift, OAuthService, SwiftUI views) depend on,
// wiring the shared cache to the RunBotCore `Keychain` enum.
//
// The cache is populated on first successful resolution and cleared by:
//   - OAuthService.signOut() via invalidateTokenCache()
//   - Keychain.save()         via invalidateTokenCache()

// MARK: - Keychain-backed TokenStore

/// Adapts the RunBotCore `Keychain` enum to `GitHubClient.TokenStore`.
///
/// The standalone `GitHubClient.KeychainTokenStore` is deliberately *not* used
/// here: it does not set `kSecUseDataProtectionKeychain`, which the RunBotCore
/// `Keychain` enum requires to avoid a legacy-keychain crash on launch (see the
/// file-level comment in `Keychain.swift`). Delegating to `Keychain` preserves
/// those exact SecItem settings, keeping token resolution behaviour unchanged.
private struct KeychainTokenStoreAdapter: TokenStore {
    /// Loads the OAuth token from the RunBotCore `Keychain`.
    nonisolated func load() -> String? { Keychain.token }
    /// Saves the OAuth token via the RunBotCore `Keychain`.
    nonisolated func save(_ token: String) -> Bool { Keychain.save(token) }
    /// Deletes the OAuth token via the RunBotCore `Keychain`.
    nonisolated func delete() -> Bool { Keychain.delete() }
}

/// Shared, process-wide token cache backing the free-function API below.
///
/// Resolution priority (unchanged from the pre-extraction implementation):
/// 1. In-memory cache
/// 2. Keychain (via `KeychainTokenStoreAdapter`)
/// 3. `GH_TOKEN` environment variable
/// 4. `GITHUB_TOKEN` environment variable
private let sharedTokenCache = TokenCache(
    tokenStore: KeychainTokenStoreAdapter(),
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
/// symbols from `Keychain.swift`, `OAuthService`, and SwiftUI views. Moving them
/// into a namespace type would require updating ~6 call-sites across 4 files for
/// no correctness benefit. The module boundary (`RunBotCore`) already provides
/// the necessary scoping.
public func invalidateTokenCache() {
    sharedTokenCache.invalidate()
}
