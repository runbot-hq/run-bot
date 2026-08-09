// ConditionalGETCache.swift
// GitHubClient

import Foundation
import os

// MARK: - ConditionalGETCache

/// A thread-safe store for conditional GET (ETag) cache entries.
///
/// Each entry is keyed by the fully-resolved URL string combined with the
/// GitHub token value, so that the same URL under different auth contexts
/// does not share a cached response.
///
/// The cache is intentionally small and internal — it is not a general-purpose
/// HTTP cache, but a targeted optimisation for the GitHub REST API where
/// conditional GETs (ETag / If-None-Match) reduce quota consumption.
///
/// ## Thread safety
/// Backed by an `OSAllocatedUnfairLock`-guarded dictionary. All reads and
/// writes are safe for concurrent access from any isolation domain.
///
/// ## Sendability
/// `ConditionalGETCache` is a value type whose stored property is a
/// `Sendable` lock — the compiler synthesises `Sendable` automatically.
internal struct ConditionalGETCache: Sendable {

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

    /// Lock-guarded backing store. The dictionary key is `"\(urlString)|\(token)"`.
    private let storage: OSAllocatedUnfairLock<[String: Entry]> = .init(initialState: [:])

    // MARK: - Lookup

    /// Returns the cached entry for `urlString` under `token`, or `nil` if
    /// no entry exists.
    ///
    /// - Parameters:
    ///   - urlString: The fully-resolved request URL string.
    ///   - token: The GitHub PAT used for the request.
    /// - Returns: The cached `Entry`, or `nil`.
    internal func entry(for urlString: String, token: String) -> Entry? {
        let key = "\(urlString)|\(token)"
        return storage.withLock { $0[key] }
    }

    // MARK: - Store

    /// Stores or replaces the cache entry for `urlString` under `token`.
    ///
    /// - Parameters:
    ///   - entry: The entry to cache.
    ///   - urlString: The fully-resolved request URL string.
    ///   - token: The GitHub PAT used for the request.
    internal func store(_ entry: Entry, for urlString: String, token: String) {
        let key = "\(urlString)|\(token)"
        storage.withLock { $0[key] = entry }
    }
}
