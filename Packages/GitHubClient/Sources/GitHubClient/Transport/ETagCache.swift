// ETagCache.swift
// GitHubClient
//
// Thread-safe actor that stores the last known ETag and response body for each
// GET URL. Used by GitHubTransport.execute() to emit conditional requests
// (If-None-Match) and return cached data on 304 Not Modified responses,
// which GitHub does not count against the primary REST API rate limit.

import Foundation

// MARK: - ETagCache

/// A thread-safe actor cache that stores (etag, data) pairs keyed by URL string.
///
/// GitHub REST API supports conditional GET requests via the ETag /
/// If-None-Match header pair. When the resource has not changed since the
/// last fetch, GitHub returns 304 Not Modified with an empty body and
/// zero rate-limit points are deducted. This dramatically reduces quota
/// consumption for polling endpoints that change infrequently.
///
/// GitHubTransport.execute() queries and updates ETagCache.shared
/// automatically for GET requests (apiAsync, apiPaginated). Mutation
/// endpoints (post, put, delete) skip the cache.
///
/// All state is isolated to the actor serial executor. Callers await every
/// access; there is no shared mutable state outside the actor.
public actor ETagCache {

  // MARK: - Shared instance

  /// The process-wide shared cache. Used by GitHubTransport by default.
  /// Tests should construct isolated ETagCache() instances to avoid
  /// cross-test contamination.
  public static let shared = ETagCache()

  // MARK: - Internal state

  private struct Entry {
    let etag: String
    let data: Data
  }

  private var store: [String: Entry] = [:]

  // MARK: - Init

  public init() {}

  // MARK: - Read

  /// Returns the cached ETag for url, or nil if no entry exists.
  public func etag(for url: String) -> String? {
    store[url]?.etag
  }

  /// Returns the cached response body for url, or nil if no entry exists.
  public func data(for url: String) -> Data? {
    store[url]?.data
  }

  // MARK: - Write

  /// Stores or replaces the (etag, data) pair for url.
  public func store(url: String, etag: String, data: Data) {
    store[url] = Entry(etag: etag, data: data)
  }

  /// Removes the cache entry for url, if any.
  public func remove(url: String) {
    store.removeValue(forKey: url)
  }

  /// Removes all cached entries.
  public func removeAll() {
    store.removeAll()
  }

  /// Returns the number of cached entries. Primarily for testing and diagnostics.
  public var count: Int { store.count }
}
