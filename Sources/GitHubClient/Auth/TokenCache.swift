// TokenCache.swift
// GitHubClient
import Foundation
import Synchronization

// MARK: - TokenCache
//
// Thread-safe in-memory cache for the resolved GitHub token.
// Populated on first successful resolution and cleared by invalidate().
// Backed by Synchronization.Mutex for synchronous, lock-guarded access.

/// A token cache that resolves from an injected `TokenStore` and/or environment variables.
/// All reads and writes are guarded by a `Mutex` for thread safety.
public final class TokenCache: Sendable {

    /// An injected `TokenStore` used to persist the token to the keychain.
    private let tokenStore: any TokenStore
    /// An optional logger for diagnostic messages.
    private let logger: (any GitHubLogger)?
    /// Thread-safe in-memory cache, initially `nil`.
    private let cache = Mutex<String?>(nil)

    /// Creates a new `TokenCache`.
    /// - Parameters:
    ///   - tokenStore: The backing store used to load/save/delete the token.
    ///   - logger: Optional logger for diagnostic messages.
    public init(tokenStore: any TokenStore, logger: (any GitHubLogger)? = nil) {
        self.tokenStore = tokenStore
        self.logger = logger
    }

    // MARK: - Public API

    /// Returns a GitHub personal access token from the first available source.
    ///
    /// Priority order:
    /// 1. In-memory cache
    /// 2. `TokenStore.load()` (e.g. Keychain OAuth token)
    /// 3. `GH_TOKEN` environment variable
    /// 4. `GITHUB_TOKEN` environment variable
    ///
    /// The `TokenStore` (step 2) is checked before environment variables (steps 3–4)
    /// because a Keychain-persisted OAuth token represents an explicit, user-initiated
    /// sign-in and should not be silently shadowed by an ambient CI/shell env var.
    /// Environment variables are the fallback for unauthenticated contexts (CI pipelines,
    /// local automation) where no interactive sign-in has occurred.
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() -> String? {
        if let cached = resolveFromCache() { return cached }
        if let stored = resolveFromStore() { return stored }
        if let envToken = resolveFromEnvironment() { return envToken }
        logger?.log("TokenCache › token() — returning nil (no token from any source)", category: "transport")
        return nil
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    public func invalidate() {
        cache.withLock { $0 = nil }
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    /// Reads the in-memory cache. Returns `nil` if not set.
    private func resolveFromCache() -> String? {
        let cached = cache.withLock { $0 }
        #if DEBUG
        if let cached {
            logger?.log("TokenCache › resolved from cache (len=\(cached.count))", category: "transport")
        }
        #endif
        return cached
    }

    /// Loads the token from the `TokenStore`. Populates the cache on success.
    ///
    /// - Note: Thundering-herd window is intentional. Two concurrent callers that
    ///   both miss `resolveFromCache()` will both call `tokenStore.load()` and both
    ///   attempt to set the cache. The `if $0 == nil { $0 = token }` check-before-write
    ///   inside the `Mutex` lock ensures only one write lands and both callers return
    ///   the same token. The double Keychain read is idempotent and cheaper than
    ///   adding a separate initialisation lock.
    private func resolveFromStore() -> String? {
        guard let token = tokenStore.load() else {
            #if DEBUG
            logger?.log("TokenCache › token store returned nil", category: "transport")
            #endif
            return nil
        }
        #if DEBUG
        logger?.log("TokenCache › resolved from store (len=\(token.count)), populating cache", category: "transport")
        #endif
        cache.withLock { if $0 == nil { $0 = token } }
        return token
    }

    /// Reads the `GH_TOKEN` or `GITHUB_TOKEN` environment variable. Populates the cache on success.
    ///
    /// ## Caching trade-off
    /// Env-var tokens are written into the shared cache (same as store-backed tokens). This
    /// mirrors the behaviour of the original `GitHubTokenCache` in `RunBotCore` and keeps
    /// the hot path consistent: once any token is resolved, every subsequent call returns
    /// immediately from `resolveFromCache()` without re-reading the env dictionary.
    ///
    /// The theoretical downside is that an env-var token is frozen for the process lifetime.
    /// In practice this is fine — `ProcessInfo.processInfo.environment` is itself immutable
    /// after launch, so there is nothing to re-read. A more conservative design would skip
    /// the cache write here and reserve the cache exclusively for store-backed tokens, but
    /// that adds complexity with no real benefit given the immutability guarantee. `invalidate()`
    /// remains the correct escape hatch if a token-rotation scenario ever arises.
    ///
    /// - Note: Same intentional thundering-herd window as `resolveFromStore()` — the
    ///   `if $0 == nil` guard inside the lock is the correct protection. The env var
    ///   read is an in-process dictionary lookup and is safe to call concurrently.
    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let envValue = ProcessInfo.processInfo.environment[key], !envValue.isEmpty {
                #if DEBUG
                logger?.log("TokenCache › resolved from env var \(key) (len=\(envValue.count)), populating cache", category: "transport")
                #endif
                cache.withLock { if $0 == nil { $0 = envValue } }
                return envValue
            }
            #if DEBUG
            logger?.log("TokenCache › env var \(key): nil/empty", category: "transport")
            #endif
        }
        return nil
    }
}
