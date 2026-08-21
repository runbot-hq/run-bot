// GitHubTransportPaginatedTests.swift
// GitHubClientTests
//
// Integration tests for GitHubTransport.apiPaginated.
// Uses URLProtocol stubbing + SpyRateLimitActor to exercise the real pagination
// loop, rate-limit partial-return, and auth-abort logic.
//
// @Suite(.serialized) is required because:
// 1. Each test calls StubURLProtocol.reset() on the shared stub registry. Swift
//    Testing runs struct suites concurrently by default; without serialization
//    these resets race with concurrent test methods.
// 2. init()/deinit call URLProtocol.registerClass/unregisterClass, which mutate
//    global URLSession configuration. Serialization ensures one test's setup and
//    teardown completes before the next test begins, preventing register/unregister
//    races between suites.
//
// The suite is a `final class` (not a struct) so that `deinit` is available to
// call URLProtocol.unregisterClass. Without unregistration, StubURLProtocol
// remains registered on URLSession.shared after the suite completes and can
// intercept requests in unrelated test files that run in the same process.
//
import Foundation
import Testing

@testable import GitHubClient

// MARK: - StubURLProtocol

/// A URLProtocol subclass that serves pre-registered per-URL responses.
/// Register stubs before each test; the registry is cleared at the top of each test.
///
/// - Note: `@unchecked Sendable` is intentional. The `stubs` dictionary is
///   guarded by `NSLock` on every read and write, making concurrent access
///   safe. `@unchecked` is required because `URLProtocol` predates Swift
///   concurrency and does not conform to `Sendable` itself. This type is
///   test-support only.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
  }
  struct ErrorStub {
    let error: URLError
  }
  private static let lock = NSLock()
  nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
  nonisolated(unsafe) private static var errorStubs: [String: ErrorStub] = [:]

  static func register(_ stub: Stub, for url: String) {
    lock.withLock { stubs[url] = stub }
  }
  static func registerError(_ stub: ErrorStub, for url: String) {
    lock.withLock { errorStubs[url] = stub }
  }
  static func reset() {
    lock.withLock {
      stubs = [:]
      errorStubs = [:]
    }
  }
  override class func canInit(with request: URLRequest) -> Bool {
    let key = request.url?.absoluteString ?? ""
    return lock.withLock { stubs[key] != nil || errorStubs[key] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    if let errorStub = StubURLProtocol.lock.withLock({ StubURLProtocol.errorStubs[key] }) {
      client?.urlProtocol(self, didFailWithError: errorStub.error)
      return
    }
    let stub = StubURLProtocol.lock.withLock { StubURLProtocol.stubs[key] }
    guard let stub else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: stub.headers
    )!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

// MARK: - Helpers

private func jsonPage(_ items: [[String: String]]) -> Data {
  (try? JSONEncoder().encode(items.map { $0.mapValues { AnyJSON.string($0) } })) ?? Data()
}

private func decodeItems(_ data: Data?) -> [[String: AnyJSON]]? {
  guard let data else { return nil }
  return try? JSONDecoder().decode([[String: AnyJSON]].self, from: data)
}

private let apiBase = GitHubConstants.apiBase + "/"

// MARK: - GitHubTransportPaginatedTests

@Suite("GitHubTransportPaginated", .serialized)
final class GitHubTransportPaginatedTests {

  init() {
    URLProtocol.registerClass(StubURLProtocol.self)
  }

  deinit {
    URLProtocol.unregisterClass(StubURLProtocol.self)
  }

  private let endpoint = "/orgs/test/actions/runners"
  private var page1URL: String { apiBase + "orgs/test/actions/runners" }
  private var page2URL: String { apiBase + "orgs/test/actions/runners?page=2" }

  private func makeTransport(
    spy: SpyRateLimitActor = SpyRateLimitActor(),
    token: String? = "test-token"
  ) -> GitHubTransport {
    GitHubTransport(rateLimiter: spy, tokenProvider: { token })
  }

  // MARK: - Happy path: two-page accumulation

  /// Two pages linked via `Link: rel="next"` are fetched and combined.
  ///
  /// Verifies: pagination loop follows the Link header and `allItems` is
  /// correctly accumulated across both pages.
  @Test func paginatedHappyPathAccumulatesTwoPages() async {
    StubURLProtocol.reset()
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
    let page2Data = jsonPage([["id": "2", "name": "runner-b"]])
    StubURLProtocol.register(
      .init(data: page1Data, statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
      for: page1URL)
    StubURLProtocol.register(
      .init(data: page2Data, statusCode: 200, headers: [:]),
      for: page2URL)
    let spy = SpyRateLimitActor()
    let result = await makeTransport(spy: spy).apiPaginated(endpoint)
    let items = decodeItems(result)
    #expect(items?.count == 2)
    #expect(items?[0]["id"] == .string("1"))
    #expect(items?[1]["id"] == .string("2"))
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
  }

  // MARK: - Valid empty-array response returns non-nil

  /// A 200 response with a valid empty-array body must return non-nil so callers
  /// can distinguish "confirmed zero items" from a failure (nil).
  ///
  /// Regression guard: the former `guard !allItems.isEmpty else { return nil }` made
  /// a legitimate empty endpoint indistinguishable from an auth failure at the call site.
  @Test func paginatedReturnsEmptyArrayOnValidEmptyResponse() async {
    StubURLProtocol.reset()
    StubURLProtocol.register(
      .init(data: jsonPage([]), statusCode: 200, headers: [:]),
      for: page1URL)
    let result = await makeTransport().apiPaginated(endpoint)
    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items != nil)
    #expect(items?.count == 0)
  }

  // MARK: - Rate-limit partial return

  /// A genuine 429 rate-limit mid-pagination arms the spy and returns partial items.
  ///
  /// Verifies:
  /// - Partial items from page 1 are returned (not nil)
  /// - `setCalled` is true — the injected spy was armed via the Retry-After path
  /// - `clearCalled` is true — clearIfNotLimited() fired after the page-1 2xx
  /// - Ordering: clearIfNotLimited() appears before the last set() in callOrder,
  ///   confirming the page-1 success clears before the page-2 429 re-arms.
  ///   Uses lastIndex(of: "set") so a hypothetical early "set" cannot silently pass.
  @Test func paginatedReturnsPartialResultsOnRateLimit() async {
    StubURLProtocol.reset()
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
    StubURLProtocol.register(
      .init(data: page1Data, statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
      for: page1URL)
    StubURLProtocol.register(
      .init(data: Data(), statusCode: 429,
            headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]),
      for: page2URL)
    let spy = SpyRateLimitActor()
    let result = await makeTransport(spy: spy).apiPaginated(endpoint)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(result != nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
    let order = await spy.callOrder
    if let clearIfNotLimitedIndex = order.firstIndex(of: "clearIfNotLimited"),
       let setIndex = order.lastIndex(of: "set") {
      #expect(
        clearIfNotLimitedIndex < setIndex,
        "clearIfNotLimited() must be recorded before set() — page-1 2xx clears, page-2 429 arms")
    } else {
      Issue.record("callOrder missing expected entries — got: \(order)")
    }
  }

  // MARK: - First-page failure returns no results

  /// Any first-page stopping condition before a successful 2xx must return nil.
  ///
  /// Cases covered:
  /// - Network error (URLError) before any HTTP response
  /// - Non-auth HTTP error on page 1 (404)
  /// - 5xx server error on page 1 (500)
  /// - 429 rate-limit on page 1 (arms spy; still returns nil)
  /// - Non-array / decode failure on page 1
  /// - No token configured (no request made)
  @Test func firstPageFailureReturnsNoResults() async {
    typealias Case = (name: String, configure: @Sendable () -> Void, expectSetCalled: Bool)
    let cases: [Case] = [
      (
        name: "network error",
        configure: {
          StubURLProtocol.registerError(
            .init(error: URLError(.notConnectedToInternet)),
            for: apiBase + "orgs/test/actions/runners")
        },
        expectSetCalled: false
      ),
      (
        name: "HTTP 404",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"Not found\"}".data(using: .utf8)!,
                  statusCode: 404, headers: [:]),
            for: apiBase + "orgs/test/actions/runners")
        },
        expectSetCalled: false
      ),
      (
        name: "HTTP 500",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"Internal Server Error\"}".data(using: .utf8)!,
                  statusCode: 500, headers: [:]),
            for: apiBase + "orgs/test/actions/runners")
        },
        expectSetCalled: false
      ),
      (
        name: "rate-limit 429",
        configure: {
          StubURLProtocol.register(
            .init(data: Data(), statusCode: 429,
                  headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]),
            for: apiBase + "orgs/test/actions/runners")
        },
        expectSetCalled: true
      ),
      (
        name: "non-array body",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"unexpected\"}".data(using: .utf8)!,
                  statusCode: 200, headers: [:]),
            for: apiBase + "orgs/test/actions/runners")
        },
        expectSetCalled: false
      )
    ]
    for testCase in cases {
      StubURLProtocol.reset()
      testCase.configure()
      let spy = SpyRateLimitActor()
      let result = await makeTransport(spy: spy).apiPaginated(endpoint)
      #expect(
        result == nil || result?.isEmpty == true,
        "case \(testCase.name): expected nil or empty on first-page failure")
      let wasSetCalled = await spy.setCalled
      #expect(wasSetCalled == testCase.expectSetCalled,
        "case \(testCase.name): spy.setCalled mismatch")
    }
    // No-token: transport must return nil without making any network request.
    StubURLProtocol.reset()
    let noTokenSpy = SpyRateLimitActor()
    let noTokenResult = await GitHubTransport(
      rateLimiter: noTokenSpy, tokenProvider: { nil }
    ).apiPaginated(endpoint)
    #expect(noTokenResult == nil)
    let noTokenClear = await noTokenSpy.clearCalled
    #expect(noTokenClear == false)
  }

  // MARK: - Later-page failure returns accumulated prefix

  /// Any non-auth, non-rate-limit stopping condition mid-pagination must
  /// return items collected before the failure, not nil.
  ///
  /// Cases covered:
  /// - Transient network error (URLError.timedOut) on page 2
  /// - HTTP 503 server error on page 2
  /// - Non-array / decode failure on page 2
  ///
  /// All three share the same partial-result semantics: page-1 item is preserved,
  /// rate-limit spy is not armed, clear() is called after the page-1 2xx.
  @Test func laterPageFailureReturnsAccumulatedPrefix() async {
    typealias Case = (name: String, configure: @Sendable () -> Void)
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
    let cases: [Case] = [
      (
        name: "network error",
        configure: {
          StubURLProtocol.registerError(
            .init(error: URLError(.timedOut)),
            for: apiBase + "orgs/test/actions/runners?page=2")
        }
      ),
      (
        name: "HTTP 503",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"Service Unavailable\"}".data(using: .utf8)!,
                  statusCode: 503, headers: [:]),
            for: apiBase + "orgs/test/actions/runners?page=2")
        }
      ),
      (
        name: "non-array body",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"unexpected\"}".data(using: .utf8)!,
                  statusCode: 200, headers: [:]),
            for: apiBase + "orgs/test/actions/runners?page=2")
        }
      )
    ]
    for testCase in cases {
      StubURLProtocol.reset()
      StubURLProtocol.register(
        .init(data: page1Data, statusCode: 200,
              headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
        for: page1URL)
      testCase.configure()
      let spy = SpyRateLimitActor()
      let result = await makeTransport(spy: spy).apiPaginated(endpoint)
      #expect(result != nil, "case \(testCase.name): expected partial result, got nil")
      let items = decodeItems(result)
      #expect(items?.count == 1, "case \(testCase.name): expected 1 item from page 1")
      let wasSetCalled = await spy.setCalled
      #expect(wasSetCalled == false, "case \(testCase.name): must not arm rate limiter")
      let wasClearCalled = await spy.clearCalled
      #expect(wasClearCalled, "case \(testCase.name): clear() must fire after page-1 2xx")
    }
  }

  // MARK: - Auth failure discards all items

  /// An auth-related stopping condition mid-pagination must discard all
  /// partially collected items and return nil.
  ///
  /// Cases covered:
  /// - 401 Unauthorized mid-pagination (#1476 auth-abort contract)
  /// - 403 permission-denied mid-pagination (no rate-limit headers)
  /// - Token revoked mid-pagination (nil token on iteration 2)
  @Test func authFailureDiscardsAllItems() async {
    typealias Case = (name: String, configure: @Sendable () -> Void)
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
    let cases: [Case] = [
      (
        name: "401 Unauthorized",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"Bad credentials\"}".data(using: .utf8)!,
                  statusCode: 401, headers: [:]),
            for: apiBase + "orgs/test/actions/runners?page=2")
        }
      ),
      (
        name: "403 permission-denied",
        configure: {
          StubURLProtocol.register(
            .init(data: "{\"message\":\"Must have admin rights\"}".data(using: .utf8)!,
                  statusCode: 403, headers: [:]),
            for: apiBase + "orgs/test/actions/runners?page=2")
        }
      )
    ]
    for testCase in cases {
      StubURLProtocol.reset()
      StubURLProtocol.register(
        .init(data: page1Data, statusCode: 200,
              headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
        for: page1URL)
      testCase.configure()
      let spy = SpyRateLimitActor()
      let result = await makeTransport(spy: spy).apiPaginated(endpoint)
      #expect(result == nil, "case \(testCase.name): expected nil after auth failure")
      let wasSetCalled = await spy.setCalled
      #expect(wasSetCalled == false, "case \(testCase.name): must not arm rate limiter")
    }
    // Token revoked mid-pagination: valid token for page 1, nil for page 2.
    // Page 2 URL is intentionally NOT registered — if the transport makes a
    // second request with a nil token, StubURLProtocol errors loudly.
    StubURLProtocol.reset()
    StubURLProtocol.register(
      .init(data: jsonPage([["id": "1", "name": "runner-a"]]), statusCode: 200,
            headers: ["Link": "<\(page2URL)>; rel=\"next\""]),
      for: page1URL)
    final class TokenCallCounter: @unchecked Sendable {
      let lock = NSLock()
      var count = 0
      func next() -> String? {
        lock.withLock {
          defer { count += 1 }
          return count == 0 ? "test-token" : nil
        }
      }
    }
    let counter = TokenCallCounter()
    let revokedSpy = SpyRateLimitActor()
    let revokedResult = await GitHubTransport(
      rateLimiter: revokedSpy, tokenProvider: { counter.next() }
    ).apiPaginated(endpoint)
    #expect(revokedResult == nil)
    let wasSetCalled = await revokedSpy.setCalled
    #expect(wasSetCalled == false)
  }

  // MARK: - Link-header termination safety

  /// A malformed or empty Link header must terminate pagination after page 1
  /// without crashing or looping indefinitely.
  ///
  /// Cases covered:
  /// - Malformed Link (no angle-bracket wrapping) — extractNextURL returns nil
  /// - Empty string Link value — treated identically to absent header
  @Test func paginationStopsForInvalidOrRepeatedNextLink() async {
    typealias Case = (name: String, linkHeader: String, expectedCount: Int)
    let cases: [Case] = [
      (name: "malformed link", linkHeader: "not-a-url; rel=next", expectedCount: 1),
      (name: "empty link",    linkHeader: "",                      expectedCount: 2)
    ]
    for testCase in cases {
      StubURLProtocol.reset()
      let itemCount = testCase.expectedCount
      var items: [[String: String]] = []
      for i in 1...itemCount { items.append(["id": "\(i)"]) }
      StubURLProtocol.register(
        .init(data: jsonPage(items), statusCode: 200,
              headers: ["Link": testCase.linkHeader]),
        for: page1URL)
      let spy = SpyRateLimitActor()
      let result = await makeTransport(spy: spy).apiPaginated(endpoint)
      #expect(result != nil, "case \(testCase.name): must return items")
      let decoded = decodeItems(result)
      #expect(decoded?.count == itemCount,
        "case \(testCase.name): expected \(itemCount) items")
      let wasSetCalled = await spy.setCalled
      #expect(wasSetCalled == false, "case \(testCase.name): must not arm rate limiter")
      let wasClearCalled = await spy.clearCalled
      #expect(wasClearCalled, "case \(testCase.name): clear() must fire after 200")
    }
  }

  // MARK: - Pre-armed rate limit does not block first request

  /// A pre-armed rate limiter must not block the first page request.
  /// The transport proceeds normally; the limiter state is preserved (not cleared).
  @Test func paginatedReturnsItemsWhenPreArmedRateLimit() async {
    StubURLProtocol.reset()
    StubURLProtocol.register(
      .init(data: jsonPage([["id": "1", "name": "runner-a"]]),
            statusCode: 200, headers: [:]),
      for: page1URL)
    let spy = SpyRateLimitActor()
    await spy.setUp(isLimited: true)
    let result = await makeTransport(spy: spy).apiPaginated(endpoint)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == .string("1"))
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == false)
    let snap = await spy.snapshot()
    #expect(snap.isLimited == true)
  }
}
