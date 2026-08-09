// ConditionalGETCache.swift
// GitHubClient

import Foundation

// MARK: - ConditionalGETCache

/// Transport-owned in-memory cache for conditional GitHub GET requests.
///
/// Entries are keyed by fully resolved request URL. If the authentication
/// token changes, all entries are discarded before the lookup or write.
///
/// Because `ConditionalGETCache` is an actor, each `GitHubTransport` instance
/// owns its own cache — copied `GitHubTransport` values still share that
/// transport's cache because actors are reference types.
internal actor ConditionalGETCache {

    // MARK: - Entry

    /// A single cached response body together with its ETag and optional
    /// `Link` header value.
    internal struct Entry: Sendable {
        /// The `ETag` response header value (including surrounding quotes,
        /// e.g. `"abc123"`).
        let etag: String
        /// The response body from the original 200 response.
        let data: Data
        /// The `Link` header value from the original 200 response, or `nil`
        /// if the response carried no `Link` header.
        let linkHeader: String?
    }

    // MARK: - Storage

    /// The current token value. When a new token is supplied, all entries
    /// are discarded before the lookup or write.
    private var token: String?
    /// URL-keyed cache entries for the current token.
    private var entries: [String: Entry] = [:]

    // MARK: - Lookup

    /// Returns the cached entry for `urlString` under `newToken`, or `nil`
    /// if no entry exists. If the token has changed since the last call,
    /// all entries are discarded first.
    ///
    /// - Parameters:
    ///   - urlString: The fully-resolved request URL string.
    ///   - newToken: The GitHub PAT used for the request.
    /// - Returns: The cached `Entry`, or `nil`.
    internal func entry(for urlString: String, token newToken: String) -> Entry? {
        resetIfTokenChanged(newToken)
        return entries[urlString]
    }

    // MARK: - Store

    /// Stores or replaces the cache entry for `urlString` under `newToken`.
    /// If the token has changed since the last call, all entries are
    /// discarded first.
    ///
    /// - Parameters:
    ///   - entry: The entry to cache.
    ///   - urlString: The fully-resolved request URL string.
    ///   - newToken: The GitHub PAT used for the request.
    internal func store(_ entry: Entry, for urlString: String, token newToken: String) {
        resetIfTokenChanged(newToken)
        entries[urlString] = entry
    }

    // MARK: - Helpers

    /// Discards all entries when `newToken` differs from the stored token.
    private func resetIfTokenChanged(_ newToken: String) {
        guard token != newToken else { return }
        token = newToken
        entries.removeAll()
    }
}
