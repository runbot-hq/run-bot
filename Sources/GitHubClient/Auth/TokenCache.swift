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

    private let tokenStore: any TokenStore
    private let logger: (any GitHubLogger)?
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
    /// 2. `TokenStore.load()`
    /// 3. `GH_TOKEN` environment variable
    /// 4. `GITHUB_TOKEN` environment variable
    ///
    /// Returns `nil` if no token is available from any source.
    public func token() -> String? {
        if let t = resolveFromCache() { return t }
        if let t = resolveFromStore() { return t }
        if let t = resolveFromEnvironment() { return t }
        logger?.log("TokenCache › token() — returning nil (no token from any source)", category: "transport")
        return nil
    }

    /// Clears the in-memory token cache. Call after saving a new token or after sign-out.
    public func invalidate() {
        cache.withLock { $0 = nil }
        logger?.log("TokenCache › invalidate — cache cleared", category: "transport")
    }

    // MARK: - Private helpers

    private func resolveFromCache() -> String? {
        let cached = cache.withLock { $0 }
        #if DEBUG
        if let cached {
            logger?.log("TokenCache › resolved from cache (len=\(cached.count))", category: "transport")
        }
        #endif
        return cached
    }

    private func resolveFromStore() -> String? {
        guard let t = tokenStore.load() else {
            #if DEBUG
            logger?.log("TokenCache › token store returned nil", category: "transport")
            #endif
            return nil
        }
        #if DEBUG
        logger?.log("TokenCache › resolved from store (len=\(t.count)), populating cache", category: "transport")
        #endif
        cache.withLock { if $0 == nil { $0 = t } }
        return t
    }

    private func resolveFromEnvironment() -> String? {
        for key in ["GH_TOKEN", "GITHUB_TOKEN"] {
            if let t = ProcessInfo.processInfo.environment[key], !t.isEmpty {
                #if DEBUG
                logger?.log("TokenCache › resolved from env var \(key) (len=\(t.count)), populating cache", category: "transport")
                #endif
                cache.withLock { if $0 == nil { $0 = t } }
                return t
            }
            #if DEBUG
            logger?.log("TokenCache › env var \(key): nil/empty", category: "transport")
            #endif
        }
        return nil
    }
}
