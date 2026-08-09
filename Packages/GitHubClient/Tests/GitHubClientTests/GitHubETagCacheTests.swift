// GitHubETagCacheTests.swift
// GitHubClientTests

import Testing
@testable import GitHubClient

@Suite("ETagCache")
struct GitHubETagCacheTests {

  // store then retrieve etag and data.
  @Test
  func store_and_retrieve() async {
    let cache = ETagCache()
    let data = Data("body".utf8)
    await cache.store(url: "https://api.github.com/test", etag: "\"v1\"",  data)
    #expect(await cache.etag(for: "https://api.github.com/test") == "\"v1\"")
    #expect(await cache.data(for: "https://api.github.com/test") == data)
  }

  // storing twice overwrites the previous value.
  @Test
  func store_twice_overwritesPrevious() async {
    let cache = ETagCache()
    await cache.store(url: "https://api.github.com/test", etag: "\"v1\"",  Data("old".utf8))
    await cache.store(url: "https://api.github.com/test", etag: "\"v2\"",  Data("new".utf8))
    #expect(await cache.etag(for: "https://api.github.com/test") == "\"v2\"")
  }

  // removeAll clears everything.
  @Test
  func removeAll_clearsAllEntries() async {
    let cache = ETagCache()
    await cache.store(url: "https://api.github.com/a", etag: "\"v1\"",  Data())
    await cache.store(url: "https://api.github.com/b", etag: "\"v2\"",  Data())
    await cache.removeAll()
    #expect(await cache.etag(for: "https://api.github.com/a") == nil)
    #expect(await cache.etag(for: "https://api.github.com/b") == nil)
  }
}
