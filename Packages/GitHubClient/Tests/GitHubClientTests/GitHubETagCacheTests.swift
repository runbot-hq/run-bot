// GitHubETagCacheTests.swift
// GitHubClientTests
//
// Unit tests for `ETagCache` — the actor that maps URL strings to (etag, data)
// pairs used by GitHubTransport for conditional GET requests.

import Foundation
import Testing
@testable import GitHubClient

// MARK: - GitHubETagCacheTests

@Suite("ETagCache")
struct GitHubETagCacheTests {

  // MARK: - Miss returns nil

  /// A fresh cache returns nil for any URL not yet stored.
  @Test
  func miss_etag_returnsNil() async {
    let cache = ETagCache()
    #expect(await cache.etag(for: "https://api.github.com/repos/owner/repo") == nil)
  }

  /// A fresh cache returns nil data for any URL not yet stored.
  @Test
  func miss_data_returnsNil() async {
    let cache = ETagCache()
    #expect(await cache.data(for: "https://api.github.com/repos/owner/repo") == nil)
  }

  // MARK: - Store then retrieve

  /// After storing, etag(for:) returns the exact stored ETag string.
  @Test
  func store_thenEtag_returnsStoredValue() async {
    let cache = ETagCache()
    let url = "https://api.github.com/repos/owner/repo/actions/runs"
    await cache.store(url: url, etag: "\"abc123\"",  Data("[]".utf8))
    #expect(await cache.etag(for: url) == "\"abc123\"")
  }

  /// After storing, data(for:) returns the exact stored body.
  @Test
  func store_thenData_returnsStoredValue() async {
    let cache = ETagCache()
    let url = "https://api.github.com/repos/owner/repo/actions/runs"
    let body = Data("[{\"id\":1}]".utf8)
    await cache.store(url: url, etag: "\"abc123\"",  body)
    #expect(await cache.data(for: url) == body)
  }

  // MARK: - Overwrite

  /// A second store for the same URL replaces both etag and data.
  @Test
  func store_twice_overwritesPrevious() async {
    let cache = ETagCache()
    let url = "https://api.github.com/repos/owner/repo/actions/runs"
    await cache.store(url: url, etag: "\"v1\"",  Data("old".utf8))
    await cache.store(url: url, etag: "\"v2\"",  Data("new".utf8))
    #expect(await cache.etag(for: url) == "\"v2\"")
    #expect(await cache.data(for: url) == Data("new".utf8))
  }

  // MARK: - Remove

  /// remove(url:) clears both etag and data for that URL.
  @Test
  func remove_clearsEntry() async {
    let cache = ETagCache()
    let url = "https://api.github.com/repos/owner/repo"
    await cache.store(url: url, etag: "\"x\"",  Data("x".utf8))
    await cache.remove(url: url)
    #expect(await cache.etag(for: url) == nil)
    #expect(await cache.data(for: url) == nil)
  }

  // MARK: - removeAll

  /// removeAll() empties the cache completely.
  @Test
  func removeAll_clearsAllEntries() async {
    let cache = ETagCache()
    await cache.store(url: "https://a.com", etag: "\"1\"",  Data("a".utf8))
    await cache.store(url: "https://b.com", etag: "\"2\"",  Data("b".utf8))
    await cache.removeAll()
    #expect(await cache.count == 0)
  }

  // MARK: - Count

  /// count reflects the number of distinct URLs stored.
  @Test
  func count_reflectsStoreCount() async {
    let cache = ETagCache()
    #expect(await cache.count == 0)
    await cache.store(url: "https://a.com", etag: "\"1\"",  Data())
    #expect(await cache.count == 1)
    await cache.store(url: "https://b.com", etag: "\"2\"",  Data())
    #expect(await cache.count == 2)
  }

  /// Storing the same URL twice does not increase count beyond 1.
  @Test
  func count_sameURL_doesNotGrowBeyondOne() async {
    let cache = ETagCache()
    await cache.store(url: "https://a.com", etag: "\"1\"",  Data())
    await cache.store(url: "https://a.com", etag: "\"2\"",  Data())
    #expect(await cache.count == 1)
  }

  // MARK: - Isolated from shared

  /// An isolated ETagCache() instance does not share state with ETagCache.shared.
  @Test
  func isolatedInstance_doesNotAffectShared() async {
    let isolated = ETagCache()
    await isolated.store(url: "https://isolated-test-url.example.com", etag: "\"z\"",  Data())
    let sharedHasIt = await ETagCache.shared.etag(for: "https://isolated-test-url.example.com")
    #expect(sharedHasIt == nil)
  }
}
