// ConditionalGETTransportTests.swift
// GitHubClientTests
//
// Focused tests for conditional GET (ETag) caching in GitHubTransport.execute().
//
// These tests verify that:
//   - A 200 with ETag is cached and the second request includes If-None-Match.
//   - A 304 does not increment the API-call counter.
//   - Paginated first-page 304 reuses its cached Link header and still requests page two.
//   - Switching tokens clears all cached entries and stale entries are not resurrected.
//
// Uses ConditionalGETStubURLProtocol for URL stubbing (its own static registry,
// separate from IsolatedStubURLProtocol used by TransportIncrementGuard).
//
// @Suite(.serialized) is required because ConditionalGETStubURLProtocol.reset() mutates
// the shared static stub registry. Without serialization, concurrent test runs
// would race on that registry.
//
import Foundation
import Testing

@testable import GitHubClient

/// Trailing-slash base URL derived from `GitHubConstants.apiBase`.
private let apiBase = GitHubConstants.apiBase + "/"

/// Encodes `[[String: String]]` to AnyJSON-compatible JSON Data.
private func jsonPage(_ items: [[String: String]]) -> Data {
  (try? JSONEncoder().encode(items.map { $0.mapValues { AnyJSON.string($0) } })) ?? Data()
}

/// Decodes a JSON Data blob back to `[[String: AnyJSON]]` for assertion.
private func decodeItems(_ data: Data?) -> [[String: AnyJSON]]? {
  guard let data else { return nil }
  return try? JSONDecoder().decode([[String: AnyJSON]].self, from: data)
}

/// Test suite for conditional GET (ETag) caching in the transport layer.
///
/// Uses `ConditionalGETStubURLProtocol` for URL stubbing (its own static registry,
/// separate from `IsolatedStubURLProtocol` used by `TransportIncrementGuard`).
/// and `MockAPICallCounter` for call-count assertions.
///
/// - Note: `.serialized` is required because `ConditionalGETStubURLProtocol.reset()` mutates
/// the shared static stub registry. Without serialization, concurrent test runs
/// would race on that registry.
@Suite(.serialized)
final class ConditionalGETTransportTests {

  /// Private `URLSession` configured with `ConditionalGETStubURLProtocol` for stubbing.
  private let session: URLSession

  /// Creates a fresh `URLSession` with `ConditionalGETStubURLProtocol` and resets the stub registry.
  init() {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ConditionalGETStubURLProtocol.self]
    session = URLSession(configuration: config)
    ConditionalGETStubURLProtocol.reset()
  }

  deinit {
    ConditionalGETStubURLProtocol.reset()
  }

  // MARK: - Test 1: 200 with ETag followed by 304

  /// Verifies that when a first request returns 200 with an ETag and a subsequent
  /// request returns 304, the second request includes `If-None-Match` and the caller
  /// receives the original body from the first response.
  @Test func etag200Then304ReturnsCachedBody() async {
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.resetLastRequest()

    let url = "\(apiBase)user"
    let body = jsonPage([["id": "42", "name": "e_tag_test"]])
    let etag = "\"abc123\""

    // First request: 200 with ETag
    ConditionalGETStubURLProtocol.register(
      .init(data: body, statusCode: 200, headers: ["ETag": etag]),
      for: url
    )

    let callCounter = MockAPICallCounter()
    let transport = GitHubTransport(
      session: session,
      tokenProvider: { "test-token" },
      callCounter: callCounter
    )

    // First call — should return the body and cache the ETag
    let firstResult = await transport.apiAsync("/user")
    #expect(firstResult != nil)
    let items = decodeItems(firstResult)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == AnyJSON.string("42"))

    // Second request: 304 Not Modified
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.register(
      .init(data: Data(), statusCode: 304, headers: [:]),
      for: url
    )

    let secondResult = await transport.execute("/user", timeout: 10, logTag: "test", conditionalGET: true)
    guard case .success(let returnedData, let statusCode, _) = secondResult else {
      Issue.record("Expected cached success, got \(secondResult)")
      return
    }
    #expect(statusCode == 200)
    #expect(returnedData == body)

    // Verify the second request included If-None-Match
    let lastReq = ConditionalGETStubURLProtocol.lastRequest()
    #expect(lastReq?.headers["If-None-Match"] == etag)
  }
// MARK: - Test 2: 304 does not increment the API-call counter

  /// Verifies that a 304 response does NOT increment the API-call counter,
  /// while the initial 200 response does.
  @Test func etag200Then304DoesNotIncrementCallCounter() async {
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.resetLastRequest()

    let url = "\(apiBase)user"
    let body = jsonPage([["id": "1", "name": "counter-test"]])
    let etag = "\"xyz789\""

    // First request: 200 with ETag
    ConditionalGETStubURLProtocol.register(
      .init(data: body, statusCode: 200, headers: ["ETag": etag]),
      for: url
    )

    let callCounter = MockAPICallCounter()
    let transport = GitHubTransport(
      session: session,
      tokenProvider: { "test-token" },
      callCounter: callCounter
    )

    // First call — 200 should increment the counter
    let firstResult = await transport.apiAsync("/user")
    #expect(firstResult != nil)
    #expect(await callCounter.recordedCount == 1)

    // Second request: 304 Not Modified
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.register(
      .init(data: Data(), statusCode: 304, headers: [:]),
      for: url
    )

    let secondResult = await transport.apiAsync("/user")
    #expect(secondResult != nil)

    // Counter should still be 1 — 304 does not count against quota
    #expect(await callCounter.recordedCount == 1)
  }

  // MARK: - Test 3: Paginated first-page 304 reuses cached Link header

  /// Verifies that when pagination encounters a 304 on the first page, the cached
  /// Link header is reused so pagination continues to page two.
  ///
  /// This guards the specific correctness hole from PR #2652 where a 304 returned
  /// `.advance(next: nil)` — truncating a multi-page response after its first page.
  @Test func paginatedFirstPage304ReusesCachedLinkHeader() async {
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.resetLastRequest()

    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let etag = "\"page1-etag\""

    // Page 1: 200 with ETag + Link header pointing to page 2
    ConditionalGETStubURLProtocol.register(
      .init(
        data: jsonPage([["id": "1", "name": "runner-a"]]),
        statusCode: 200,
        headers: ["ETag": etag, "Link": "<\(page2URL)>; rel=\"next\""]
      ),
      for: page1URL
    )

    // Page 2: 200 with a different item
    ConditionalGETStubURLProtocol.register(
      .init(
        data: jsonPage([["id": "2", "name": "runner-b"]]),
        statusCode: 200,
        headers: [:]
      ),
      for: page2URL
    )

    let callCounter = MockAPICallCounter()
    let transport = GitHubTransport(
      session: session,
      tokenProvider: { "test-token" },
      callCounter: callCounter
    )

    // First call — collects both pages (2 items)
    let firstResult = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(firstResult != nil)
    let firstItems = decodeItems(firstResult)
    #expect(firstItems?.count == 2)
    #expect(firstItems?[0]["name"] == AnyJSON.string("runner-a"))
    #expect(firstItems?[1]["name"] == AnyJSON.string("runner-b"))
    let firstCallCount = await callCounter.recordedCount
    #expect(firstCallCount == 2) // 2 pages = 2 calls

    // Now re-stub: page 1 returns 304, page 2 still returns 200
    ConditionalGETStubURLProtocol.reset()
    ConditionalGETStubURLProtocol.register(
      .init(data: Data(), statusCode: 304, headers: [:]),
      for: page1URL
    )
    ConditionalGETStubURLProtocol.register(
      .init(
        data: jsonPage([["id": "3", "name": "runner-c"]]),
        statusCode: 200,
        headers: [:]
      ),
      for: page2URL
    )

    // Second call — page 1 returns 304 with cached body + Link header,
    // so pagination continues to page 2 and collects both cached and new items.
    let secondResult = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(secondResult != nil)
    let secondItems = decodeItems(secondResult)
    // Page 1 returns cached [runner-a], page 2 returns [runner-c]
    #expect(secondItems?.count == 2)
    #expect(secondItems?[0]["name"] == AnyJSON.string("runner-a"))
    #expect(secondItems?[1]["name"] == AnyJSON.string("runner-c"))

    // Page 1 was 304 (not counted), page 2 was 200 (counted)
    let secondCallCount = await callCounter.recordedCount
    #expect(secondCallCount == firstCallCount + 1)
  }

  // MARK: - Test 4: Token change clears previous entries

  /// Verifies that switching authentication tokens clears all cached entries.
  /// A token A entry is stored, token B lookup returns nil, and switching
  /// back to token A does not resurrect stale entries.
  @Test func tokenChangeClearsPreviousEntries() async {
    let cache = ConditionalGETCache()

    let url = "https://api.github.com/user"
    let entry = ConditionalGETCache.Entry(
      etag: "\"token-a-etag\"",
      data: Data("token-a-body".utf8),
      linkHeader: nil
    )

    await cache.store(entry, for: url, token: "token-a")

    // Token A can retrieve its own entry.
    #expect(await cache.entry(for: url, token: "token-a") != nil)

    // Switching to token B clears token A entries.
    #expect(await cache.entry(for: url, token: "token-b") == nil)

    // Switching back to token A must not resurrect the old entry.
    #expect(await cache.entry(for: url, token: "token-a") == nil)
  }
}
