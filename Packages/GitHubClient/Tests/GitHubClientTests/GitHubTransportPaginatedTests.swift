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
///   test-support only — P4's "no @unchecked Sendable in production types"
///   does not apply here.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  /// A single canned response for one URL.
  struct Stub {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
  }

  /// A stub that produces a URLError instead of an HTTP response.
  struct ErrorStub {
    let error: URLError
  }

  // `nonisolated(unsafe)` — the two stored `var` properties are manually protected by
  // `lock` below; Swift 6 strict concurrency requires the annotation for static stored
  // properties on Sendable types that are not actor-isolated.
  // The `lock` constant itself does not need the annotation: `NSLock` is already
  // `Sendable` and immutable after initialisation.
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

    // Error stub takes priority.
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

/// Encodes `[[String: String]]` to AnyJSON-compatible JSON Data.
private func jsonPage(_ items: [[String: String]]) -> Data {
  (try? JSONEncoder().encode(items.map { $0.mapValues { AnyJSON.string($0) } })) ?? Data()
}

/// Decodes a JSON Data blob back to `[[String: AnyJSON]]` for assertion.
private func decodeItems(_ data: Data?) -> [[String: AnyJSON]]? {
  guard let data else { return nil }
  return try? JSONDecoder().decode([[String: AnyJSON]].self, from: data)
}

/// Trailing-slash base URL derived from `GitHubConstants.apiBase`.
/// All stub URL construction uses this so that if apiBase ever changes
/// (e.g. GHE support), test URLs stay in sync automatically.
private let apiBase = GitHubConstants.apiBase + "/"

// MARK: - GitHubTransportPaginatedTests

/// Integration tests for `GitHubTransport.apiPaginated`.
///
/// Strategy: register `StubURLProtocol` on `URLSession.shared`'s configuration,
/// inject a `SpyRateLimitActor` and an explicit `tokenProvider` closure directly
/// into a `GitHubTransport` instance. Each test constructs its own transport —
/// no shared global state is mutated for token or rate-limiter concerns.
///
/// `.serialized` is still required because `StubURLProtocol.reset()` mutates the
/// shared stub registry. Without serialization, concurrent test runs would race
/// on that registry.
///
/// The suite is a `final class` so that `deinit` is available to call
/// `URLProtocol.unregisterClass`. Swift Testing supports class-based suites;
/// `@Suite` and `@Test` behave identically to the struct form.
@Suite("GitHubTransportPaginated", .serialized)
final class GitHubTransportPaginatedTests {

  init() {
    URLProtocol.registerClass(StubURLProtocol.self)
  }

  deinit {
    // Unregister so StubURLProtocol does not intercept requests in other
    // test suites that run in the same process after this suite completes.
    URLProtocol.unregisterClass(StubURLProtocol.self)
  }

  // MARK: - Happy path: two-page accumulation

  /// Two pages linked via `Link: rel="next"` are fetched and combined.
  ///
  /// Verifies: pagination loop follows the Link header and `allItems` is
  /// correctly accumulated across both pages.
  @Test func paginatedHappyPathAccumulatesTwoPages() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])
    let page2Data = jsonPage([["id": "2", "name": "runner-b"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    StubURLProtocol.register(
      .init(
        data: page2Data,
        statusCode: 200,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    let items = decodeItems(result)
    #expect(items?.count == 2)
    #expect(items?[0]["id"] == .string("1"))
    #expect(items?[1]["id"] == .string("2"))
    // A successful run must clear any previously-armed rate limit.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
  }

  // MARK: - Valid empty-array response returns non-nil

  /// A 200 response with a valid empty-array body (`[]`) must return non-nil
  /// so callers can distinguish "confirmed zero items" from a failure (nil).
  ///
  /// Regression guard for the former `guard !allItems.isEmpty else { return nil }`
  /// which made a legitimate empty endpoint (e.g. an org with no registered runners)
  /// indistinguishable from an auth failure at the call site. If the store falls back
  /// to cached data on nil, a zero-runner response would permanently show stale entries.
  ///
  /// Verifies:
  /// - `result != nil` — a valid 200 [] must not be collapsed to a failure
  /// - `items` decodes to an empty array (not nil, not a non-empty array)
  @Test func paginatedReturnsEmptyArrayOnValidEmptyResponse() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    // Valid 200 with an empty JSON array — e.g. org has no registered runners.
    StubURLProtocol.register(
      .init(
        data: jsonPage([]),
        statusCode: 200,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Must be non-nil: a valid empty response is distinguishable from a failure.
    #expect(result != nil)
    // Must decode to an empty array, not nil.
    let items = decodeItems(result)
    #expect(items != nil)
    #expect(items?.count == 0)
  }

  // MARK: - Non-array body stops pagination gracefully

  /// A 200 response with a non-array JSON body stops pagination and returns
  /// items collected so far (not nil, not a crash).
  ///
  /// Verifies: the labeled `break pagination` on the decode-failure path exits
  /// the while loop correctly (regression guard for the unlabeled-break bug).
  @Test func paginatedStopsOnNonArrayBody() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1"]])
    // Non-array body on page 2 — e.g. a GitHub error object.
    let badData = "{\"message\":\"unexpected\"}".data(using: .utf8)!

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    StubURLProtocol.register(
      .init(
        data: badData,
        statusCode: 200,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Page 1 was accumulated before the bad page stopped things.
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == .string("1"))
  }

  // MARK: - Non-array body on the very first page

  /// A 200 response with a non-array JSON body on the *first* page must return nil
  /// and must NOT arm the rate-limit actor (clear() IS called because execute()
  /// clears on any 2xx before the decode step).
  ///
  /// Renamed from paginatedNonArrayFirstPageDoesNotArmRateLimiter: the test also
  /// asserts result == nil, which the old name did not reflect.
  @Test func paginatedNonArrayFirstPage_returnsNilAndDoesNotArmRateLimiter() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    // 200 with a non-array body on the very first page — e.g. GitHub returns
    // an error object instead of the expected runner list.
    let badData = "{\"message\":\"Not Found\",\"documentation_url\":\"https://docs.github.com\"}"
      .data(using: .utf8)!
    StubURLProtocol.register(
      .init(
        data: badData,
        statusCode: 200,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // hadAtLeastOneSuccessfulPage is false — nil must be returned.
    #expect(result == nil)
    // A 200 with a non-array body is not a rate-limit event — set() must not fire.
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    // clear() IS called — execute() calls clearIfNotLimited() on every 2xx.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == true)
  }

  // MARK: - Single-page (no Link header) happy path

  /// A single page with no `Link: rel="next"` header returns just that page's items.
  ///
  /// Verifies: `extractNextURL(from: nil)` returns `nil`, terminating the pagination
  /// loop after the first page. This is the common case for endpoints that return
  /// all results in one response.
  @Test func paginatedSinglePageReturnsItems() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    // No Link header — just a single page.
    StubURLProtocol.register(
      .init(
        data: jsonPage([["id": "1", "name": "runner-a"], ["id": "2", "name": "runner-b"]]),
        statusCode: 200,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    let items = decodeItems(result)
    #expect(items?.count == 2)
    #expect(items?[0]["id"] == .string("1"))
    #expect(items?[1]["id"] == .string("2"))
  }

  // MARK: - Rate-limit on first page returns nil

  /// A 429 on the very first page with zero items accumulated must return nil.
  ///
  /// Verifies the documented contract:
  /// "Returns nil when a stopping condition occurs before any items are accumulated
  /// (e.g. rate-limited or network error on the very first page)."
  @Test func paginatedReturnsNilOnRateLimitFirstPage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    StubURLProtocol.register(
      .init(
        data: Data(),
        statusCode: 429,
        headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result == nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled)
    // clear() must NOT be called — no 2xx page succeeded before the 429.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == false)
  }

  // MARK: - Rate-limit partial return

  /// A genuine 429 rate-limit mid-pagination arms the spy and returns partial items.
  ///
  /// Verifies:
  /// - Partial items from page 1 are returned (not nil)
  /// - `setCalled` is true — the injected spy (not the global) was armed
  /// - `clearCalled` is true — clearIfNotLimited() fired after the page-1 2xx response
  /// - **Ordering**: clearIfNotLimited() is recorded before the *last* set() in
  ///   `callOrder`, confirming the page-1 success clears the limiter before the
  ///   page-2 429 re-arms it. Using `lastIndex(of: "set")` (not `firstIndex`) ensures
  ///   a future code path that emits "set" before the pagination loop cannot silently
  ///   pass the check by having `firstIndex(of: "set")` point to that earlier entry.
  ///
  ///   `callOrder` after a normal two-page run looks like:
  ///   `["clearIfNotLimited", "clear", "set"]`
  ///   The ordering assertion keys on `"clearIfNotLimited"` (the protocol call
  ///   the transport actually makes on a 2xx) rather than `"clear"` (an internal
  ///   delegation detail). This makes the assertion resilient to a future refactor
  ///   that inlines clearIfNotLimited() instead of delegating to clear().
  ///
  /// - Note: 429 is chosen over 403 because the GitHub API uses 429 exclusively
  ///   for genuine rate limits. The stub includes a `Retry-After: 60` header so
  ///   `handleRateLimitResponse` arms the actor via the `Retry-After` path (the
  ///   primary path), not the `X-RateLimit-Reset` fallback. Do not swap this to a
  ///   403 without also verifying the spy's `set(resetAt:)` is still called.
  @Test func paginatedReturnsPartialResultsOnRateLimit() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    // 429 on page 2 — genuine rate limit. Retry-After: 60 arms the actor via
    // the primary header path (not the X-RateLimit-Reset fallback).
    StubURLProtocol.register(
      .init(
        data: Data(),
        statusCode: 429,
        headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Partial results from page 1 must be returned.
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(result != nil)
    // The injected spy — not the global — must have been armed.
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
    // Ordering assertion: clearIfNotLimited() must appear before the last set() in
    // callOrder. lastIndex(of: "set") is intentional — it ensures a hypothetical
    // early "set" emission (before the pagination loop) cannot hide a regression
    // where the real rate-limit set() fires before clearIfNotLimited().
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

  // MARK: - Transient network error returns partial results

  /// A transient network error (e.g. timeout) mid-pagination must return the
  /// items collected so far — not nil.
  ///
  /// Verifies the documented contract:
  /// "Returns partial results (not nil) if pagination is stopped by a transient
  /// network error."
  ///
  /// Mechanism: page 1 succeeds (200 + Link header). Page 2 throws
  /// `URLError(.timedOut)` via `StubURLProtocol.registerError`. The pagination
  /// loop matches `.networkError`, exits via `break pagination`, and returns
  /// `allItems` — which contains the one item from page 1.
  ///
  /// Three assertions:
  /// - `result != nil` — partial items are returned, not discarded
  /// - `items.count == 1` — only the page-1 item is present
  /// - `spy.setCalled == false` — a network error must never arm the rate limiter
  @Test func paginatedReturnsPartialResultsOnTransientNetworkError() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    // Page 2 throws a transient network error — simulates a timeout mid-pagination.
    StubURLProtocol.registerError(
      .init(error: URLError(.timedOut)),
      for: page2URL
    )

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Partial item from page 1 must be returned — not nil.
    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    // clear() IS called after page 1 success (2xx response clears the limiter).
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
    // A transient network error must never arm the rate-limit actor.
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
  }

  // MARK: - Permission-denied discards all items

  /// A plain 403 with no rate-limit headers is permission-denied: partial items
  /// are discarded and nil is returned. The spy must NOT be armed.
  ///
  /// Verifies: `.permissionDenied` path returns nil, and `SpyRateLimitActor.setCalled`
  /// is false — confirming the injected actor distinguishes rate-limit from perm-denied.
  @Test func paginatedReturnsNilOnPermissionDenied() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    // Plain 403, no Retry-After, no X-RateLimit-Remaining: 0 — permission error.
    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Must have admin rights\"}".data(using: .utf8)!,
        statusCode: 403,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result == nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    // clear() IS called after page 1 success (2xx response clears the limiter).
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
  }

  // MARK: - 401 auth failure discards all items

  /// A 401 mid-pagination must discard all partially collected items and return nil.
  ///
  /// Verifies: `.httpError(401)` triggers `didFailAuth`, and the auth-abort
  /// semantics introduced in the #1476 refactor are preserved.
  @Test func paginatedReturnsNilOnAuthFailure401() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Bad credentials\"}".data(using: .utf8)!,
        statusCode: 401,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Partial item from page 1 must be discarded — nil returned.
    #expect(result == nil)
    // clear() IS called after page 1 success (2xx response clears the limiter).
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
  }

  // MARK: - No token returns nil immediately

  /// When no GitHub token is configured, `apiPaginated` returns nil
  /// without making any network request.
  @Test func paginatedReturnsNilWhenNoToken() async {
    StubURLProtocol.reset()

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { nil })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(result == nil)
    // clear() must NOT be called — no-token returns without making a request.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == false)
  }

  // MARK: - Token revoked mid-pagination discards all items

  /// A token that is valid for page 1 but revoked (returns nil) before page 2 is
  /// requested must cause all partial items to be discarded and nil to be returned.
  ///
  /// Mechanism: `TokenCallCounter` returns "test-token" on the first call and nil
  /// on every subsequent call. The transport checks the token at the start of each
  /// page loop iteration; a nil token on iteration 2 hits the no-token guard and
  /// returns nil (discarding the page-1 item).
  ///
  /// Two assertions:
  /// - `result == nil` — partial items are discarded on mid-pagination token loss
  /// - `spy.setCalled == false` — a missing token is not a rate-limit event
  ///
  /// Note: page 2 is intentionally NOT registered in StubURLProtocol. If the
  /// transport ever makes a second network request with a nil token instead of
  /// aborting early, StubURLProtocol will error with URLError(.fileDoesNotExist)
  /// and the test will fail loudly — providing an automatic regression sentinel
  /// for the no-token early-exit path.
  @Test func paginatedReturnsNilWhenTokenRevokedMidPagination() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    // page2URL is intentionally NOT registered — see test doc comment above.

    /// A call-counting token provider that returns a valid token exactly once.
    ///
    /// `@unchecked Sendable` is intentional: `count` is a plain `Int` protected
    /// by `NSLock` on every read-modify-write. `@unchecked` is required because
    /// the class has no actor isolation and Swift 6 strict concurrency cannot
    /// verify the lock-based safety statically. This type is test-support only.
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
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { counter.next() })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result == nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
  }

  // MARK: - Pre-armed rate limit does not block first request

  @Test func paginatedReturnsItemsWhenPreArmedRateLimit() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    StubURLProtocol.register(
      .init(
        data: jsonPage([["id": "1", "name": "runner-a"]]),
        statusCode: 200,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    await spy.setUp(isLimited: true)

    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

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

  // MARK: - Non-auth HTTP error (404) returns partial results

  @Test func paginatedReturnsPartialResultsOnHttpError404() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Not found\"}".data(using: .utf8)!,
        statusCode: 404,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == .string("1"))
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
  }

  // MARK: - Non-auth HTTP error on the very first page returns nil

  @Test func paginatedReturnsNilOnHttpErrorFirstPage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Not found\"}".data(using: .utf8)!,
        statusCode: 404,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result == nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == false)
  }

  // MARK: - 5xx server error on first page returns nil

  /// A 500 Internal Server Error on the very first page must return nil and must
  /// not arm the rate-limit actor or call clear().
  ///
  /// 5xx responses on the first page are treated identically to non-auth 4xx errors:
  /// `hadAtLeastOneSuccessfulPage` is false, so nil is returned rather than an empty
  /// array. The transport does not attempt a retry — that is the caller's responsibility.
  ///
  /// This is Step 2 of the PR #41 audit: explicit 5xx coverage on the first-page path.
  ///
  /// Three assertions:
  /// - `result == nil` — no items were collected before the error
  /// - `spy.setCalled == false` — a server error is not a rate-limit event
  /// - `spy.clearCalled == false` — no 2xx preceded the error, so the limiter is untouched
  @Test func paginatedReturnsNilOnServerError500FirstPage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Internal Server Error\"}".data(using: .utf8)!,
        statusCode: 500,
        headers: [:]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result == nil)
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == false)
  }

  // MARK: - 503 server error mid-pagination returns partial results

  /// A 503 Service Unavailable mid-pagination must return the items collected
  /// so far — not nil — and must not arm the rate-limit actor.
  ///
  /// This exercises the partial-result preservation path for 5xx errors: unlike
  /// auth failures (401, 403) which discard all accumulated items and return nil,
  /// a server error mid-pagination is treated as a stopping condition that preserves
  /// whatever was successfully fetched before the error.
  ///
  /// Mechanism: page 1 succeeds (200 + Link header, one item). Page 2 returns 503.
  /// The pagination loop exits via the server-error branch and returns `allItems`
  /// containing the one item from page 1.
  ///
  /// Four assertions:
  /// - `result != nil` — partial items are preserved, not discarded
  /// - `items.count == 1` — exactly the item from page 1
  /// - `spy.setCalled == false` — a server error is not a rate-limit event
  /// - `spy.clearCalled == true` — page 1 returned 200, so clearIfNotLimited() fired
  @Test func paginatedReturnsPartialResultsOnServerError503MidPagination() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    let page1Data = jsonPage([["id": "1", "name": "runner-a"]])

    StubURLProtocol.register(
      .init(
        data: page1Data,
        statusCode: 200,
        headers: ["Link": "<\(page2URL)>; rel=\"next\""]
      ), for: page1URL)
    StubURLProtocol.register(
      .init(
        data: "{\"message\":\"Service Unavailable\"}".data(using: .utf8)!,
        statusCode: 503,
        headers: [:]
      ), for: page2URL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == .string("1"))
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == true)
  }

  // MARK: - Malformed Link header terminates pagination gracefully

  /// A `Link` header with no angle-bracket wrapping around the URL portion
  /// must cause `extractNextURL` to return nil, terminating pagination after
  /// the first page without crashing or looping.
  ///
  /// The value `"not-a-url; rel=next"` is one specific invalid shape — no
  /// `<...>` brackets. Other malformed shapes (e.g. angle brackets present
  /// but non-URL content inside) are not covered by this test.
  ///
  /// Three assertions:
  /// - `result != nil` — page-1 items are preserved, not discarded
  /// - `items.count == 1` — exactly the one item from page 1
  /// - `spy.setCalled == false` — a parse failure is not a rate-limit event
  @Test func paginatedMalformedLinkHeaderTerminatesSinglePage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    // Respond with a garbage Link header — no angle brackets, no valid URL.
    StubURLProtocol.register(
      .init(
        data: jsonPage([["id": "1", "name": "runner-a"]]),
        statusCode: 200,
        headers: ["Link": "not-a-url; rel=next"]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // extractNextURL must return nil — pagination terminates after page 1.
    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items?.count == 1)
    #expect(items?[0]["id"] == .string("1"))
    // A Link parse failure is not a rate-limit event.
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    // clear() IS called — page 1 returned 200.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == true)
  }

  // MARK: - Empty Link header value terminates pagination gracefully

  /// An empty string `Link` header value must be treated identically to no
  /// `Link` header: `extractNextURL` returns nil, pagination terminates after
  /// page 1, and collected items are returned.
  ///
  /// Some proxies or GitHub Enterprise installations strip the Link header
  /// content while leaving the header key present. This test confirms the
  /// parser handles that silently rather than crashing.
  ///
  /// Three assertions:
  /// - `result != nil` — items from page 1 are preserved
  /// - `items.count == 2` — both items from the single page are present
  /// - `spy.setCalled == false` — empty Link is not a rate-limit event
  @Test func paginatedEmptyLinkHeaderTerminatesAfterFirstPage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"

    // Empty Link header value — simulates a proxy that strips the URL portion.
    StubURLProtocol.register(
      .init(
        data: jsonPage([["id": "1", "name": "runner-a"], ["id": "2", "name": "runner-b"]]),
        statusCode: 200,
        headers: ["Link": ""]
      ), for: pageURL)

    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")

    // Empty Link — treated as no next page.
    #expect(result != nil)
    let items = decodeItems(result)
    #expect(items?.count == 2)
    // Empty Link is not a rate-limit event.
    let wasSetCalled = await spy.setCalled
    #expect(wasSetCalled == false)
    // clear() IS called — page 1 returned 200.
    let wasClearCalled = await spy.clearCalled
    #expect(wasClearCalled == true)
  }
}
