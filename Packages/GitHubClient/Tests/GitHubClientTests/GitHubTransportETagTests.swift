// GitHubTransportETagTests.swift
// GitHubClientTests
//
// Integration tests for GitHubTransport ETag / conditional-request behaviour.
//
// Verifies:
//   1. A 200 response stores the ETag + body in the supplied ETagCache.
//   2. A 304 response returns the cached body and does NOT increment callCounter.
//   3. When a cached ETag exists, the transport injects `If-None-Match` on the
//      outgoing request.
//
// Uses StubURLProtocol (defined in GitHubTransportPaginatedTests.swift) +
// MockAPICallCounter (TestSupport/) to avoid any real network traffic.
//
// .serialized is required: tests mutate the shared StubURLProtocol registry.

import Foundation
import Testing
@testable import GitHubClient

@Suite("GitHubTransport ETag", .serialized)
final class GitHubTransportETagTests {

  init() { URLProtocol.registerClass(StubURLProtocol.self) }
  deinit  { URLProtocol.unregisterClass(StubURLProtocol.self) }

  // MARK: - Helpers

  /// Builds a GitHubTransport backed by URLSession.shared (intercepted by StubURLProtocol).
  private func makeTransport(counter: MockAPICallCounter = MockAPICallCounter()) -> GitHubTransport {
    GitHubTransport(
      session: .shared,
      tokenProvider: { "test-token" },
      callCounter: counter
    )
  }

  // MARK: - 200 stores ETag in cache

  /// A 200 response that carries an `ETag` header must be stored in the supplied cache.
  @Test
  func execute_200_storesETagInCache() async {
    StubURLProtocol.reset()
    let url = GitHubConstants.apiBase + "/repos/owner/repo/actions/runs"
    let body = Data("[{\"id\":1}]".utf8)
    StubURLProtocol.register(
      .init( body, statusCode: 200, headers: ["ETag": "\"etag-v1\""]),
      for: url
    )
    let cache = ETagCache()
    let transport = makeTransport()
    _ = await transport.execute(url, timeout: 10, logTag: "test", etagCache: cache)
    #expect(await cache.etag(for: url) == "\"etag-v1\"")
    #expect(await cache.data(for: url) == body)
  }

  // MARK: - 304 returns cached data, does not increment counter

  /// A 304 response must return the previously-cached body as `.notModified`
  /// and must NOT call `callCounter.record()`.
  @Test
  func execute_304_returnsCachedData_andDoesNotIncrementCounter() async {
    StubURLProtocol.reset()
    let url = GitHubConstants.apiBase + "/repos/owner/repo/actions/runs"
    let cachedBody = Data("[{\"id\":42}]".utf8)
    // Stub returns a 304 with empty body.
    StubURLProtocol.register(
      .init( Data(), statusCode: 304, headers: [:]),
      for: url
    )
    // Pre-seed the cache as if a prior 200 had stored etag + body.
    let cache = ETagCache()
    await cache.store(url: url, etag: "\"etag-v1\"",  cachedBody)

    let counter = MockAPICallCounter()
    let transport = makeTransport(counter: counter)
    let result = await transport.execute(url, timeout: 10, logTag: "test", etagCache: cache)

    guard case .notModified(let returned) = result else {
      Issue.record("Expected .notModified, got \(result)")
      return
    }
    #expect(returned == cachedBody, "304 should return the cached body")
    #expect(await counter.recordedCount == 0, "304 must not consume a rate-limit point")
  }

  // MARK: - If-None-Match is injected when cache has an ETag

  /// When the cache has a stored ETag for a URL, the outgoing request must
  /// carry `If-None-Match` with that value.
  ///
  /// Strategy: register a stub that echoes the received `If-None-Match` header
  /// back in the response body so we can assert on it without needing a
  /// request-capture protocol.
  /// Since URLProtocol doesn't let us inspect the request inside startLoading
  /// from the outside, we instead:
  ///   - pre-seed the cache with an ETag
  ///   - stub a 200 response
  ///   - verify the cache is NOT re-stored with a new ETag (i.e. we got a fresh 200)
  ///   This is an indirect test; the direct path is tested by verifying the 304 flow
  ///   works end-to-end (which requires If-None-Match to be present).
  ///
  /// For a direct assertion, we use a CapturingURLProtocol that records the request.
  @Test
  func execute_withCachedETag_injectsIfNoneMatchHeader() async {
    // Use a separate capturing protocol to inspect outgoing request headers.
    URLProtocol.registerClass(CapturingURLProtocol.self)
    defer { URLProtocol.unregisterClass(CapturingURLProtocol.self) }
    CapturingURLProtocol.reset()

    let url = GitHubConstants.apiBase + "/repos/owner/repo/actions/runs"
    let cachedBody = Data("[]".utf8)
    let etag = "\"etag-stored\""
    // Register a 200 so the transport doesn't fall back to StubURLProtocol.
    CapturingURLProtocol.register(
      .init( cachedBody, statusCode: 200, headers: [:]),
      for: url
    )
    let cache = ETagCache()
    await cache.store(url: url, etag: etag,  cachedBody)

    let transport = makeTransport()
    _ = await transport.execute(url, timeout: 10, logTag: "test", etagCache: cache)

    let captured = CapturingURLProtocol.capturedRequest(for: url)
    #expect(captured?.value(forHTTPHeaderField: "If-None-Match") == etag)
  }
}

// MARK: - CapturingURLProtocol

/// A URLProtocol that records the last `URLRequest` received for each URL,
/// then serves a pre-registered stub response. Used to assert outgoing headers.
final class CapturingURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub { let data: Data; let statusCode: Int; let headers: [String: String] }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
  nonisolated(unsafe) private static var captured: [String: URLRequest] = [:]

  static func register(_ stub: Stub, for url: String) {
    lock.withLock { stubs[url] = stub }
  }
  static func reset() {
    lock.withLock { stubs = [:]; captured = [:] }
  }
  static func capturedRequest(for url: String) -> URLRequest? {
    lock.withLock { captured[url] }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    let key = request.url?.absoluteString ?? ""
    return lock.withLock { stubs[key] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    CapturingURLProtocol.lock.withLock { CapturingURLProtocol.captured[key] = request }
    guard let stub = CapturingURLProtocol.lock.withLock({ CapturingURLProtocol.stubs[key] }) else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1", headerFields: stub.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
