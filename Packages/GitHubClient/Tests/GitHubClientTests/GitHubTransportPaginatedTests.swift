// GitHubTransportPaginatedTests.swift
// GitHubClientTests

import Foundation
import Testing
@testable import GitHubClient

// MARK: - StubURLProtocol

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub { let  Data; let statusCode: Int; let headers: [String: String] }
  struct ErrorStub { let error: URLError }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var stubs: [String: Stub] = [:]
  nonisolated(unsafe) private static var errorStubs: [String: ErrorStub] = [:]

  static func register(_ stub: Stub, for url: String) { lock.withLock { stubs[url] = stub } }
  static func registerError(_ stub: ErrorStub, for url: String) { lock.withLock { errorStubs[url] = stub } }
  static func reset() { lock.withLock { stubs = [:]; errorStubs = [:] } }

  override class func canInit(with request: URLRequest) -> Bool {
    let key = request.url?.absoluteString ?? ""
    return lock.withLock { stubs[key] != nil || errorStubs[key] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    if let errorStub = StubURLProtocol.lock.withLock({ StubURLProtocol.errorStubs[key] }) {
      client?.urlProtocol(self, didFailWithError: errorStub.error); return
    }
    let stub = StubURLProtocol.lock.withLock { StubURLProtocol.stubs[key] }
    guard let stub else { client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist)); return }
    let response = HTTPURLResponse(url: request.url!, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: stub.headers)!
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

private func decodeItems(_  Data?) -> [[String: AnyJSON]]? {
  guard let data else { return nil }
  return try? JSONDecoder().decode([[String: AnyJSON]].self, from: data)
}

private let apiBase = GitHubConstants.apiBase + "/"

// MARK: - Suite

@Suite("GitHubTransportPaginated", .serialized)
final class GitHubTransportPaginatedTests {

  private let stubSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }()

  // Two pages linked via Link: rel="next" are fetched and combined.
  @Test func paginatedHappyPathAccumulatesTwoPages() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    StubURLProtocol.register(.init( jsonPage([["id": "1", "name": "runner-a"]]), statusCode: 200, headers: ["Link": "<\(page2URL)>; rel=\"next\""]), for: page1URL)
    StubURLProtocol.register(.init( jsonPage([["id": "2", "name": "runner-b"]]), statusCode: 200, headers: [:]), for: page2URL)
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(session: stubSession, rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    let items = decodeItems(result)
    #expect(items?.count == 2)
    #expect(items?[0]["id"] == .string("1"))
    #expect(items?[1]["id"] == .string("2"))
    #expect(await spy.clearCalled)
  }

  // 200 with empty array body returns non-nil (not collapsed to failure).
  @Test func paginatedReturnsEmptyArrayOnValidEmptyResponse() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"
    StubURLProtocol.register(.init( jsonPage([]), statusCode: 200, headers: [:]), for: pageURL)
    let transport = GitHubTransport(session: stubSession, rateLimiter: SpyRateLimitActor(), tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(result != nil)
    #expect(decodeItems(result)?.count == 0)
  }

  // 429 on the first page -> nil result, rate limiter armed, never cleared.
  @Test func paginatedReturnsNilOnRateLimitFirstPage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"
    StubURLProtocol.register(.init( Data(), statusCode: 429, headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]), for: pageURL)
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(session: stubSession, rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(result == nil)
    #expect(await spy.setCalled)
    #expect(await spy.clearCalled == false)
  }

  // 429 mid-pagination -> partial items returned, limiter armed after page-1 clear.
  @Test func paginatedReturnsPartialResultsOnRateLimit() async {
    StubURLProtocol.reset()
    let page1URL = "\(apiBase)orgs/test/actions/runners"
    let page2URL = "\(apiBase)orgs/test/actions/runners?page=2"
    StubURLProtocol.register(.init( jsonPage([["id": "1", "name": "runner-a"]]), statusCode: 200, headers: ["Link": "<\(page2URL)>; rel=\"next\""]), for: page1URL)
    StubURLProtocol.register(.init( Data(), statusCode: 429, headers: ["Retry-After": "60", "X-RateLimit-Remaining": "0"]), for: page2URL)
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(session: stubSession, rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(decodeItems(result)?.count == 1)
    #expect(await spy.setCalled)
    #expect(await spy.clearCalled)
    let order = await spy.callOrder
    if let ci = order.firstIndex(of: "clearIfNotLimited"), let si = order.lastIndex(of: "set") {
      #expect(ci < si, "page-1 2xx must clear before page-2 429 arms")
    } else {
      Issue.record("callOrder missing entries: \(order)")
    }
  }

  // No token -> nil, no request made, rate limiter untouched.
  @Test func paginatedReturnsNilWhenNoToken() async {
    StubURLProtocol.reset()
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(session: stubSession, rateLimiter: spy, tokenProvider: { nil })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(result == nil)
    #expect(await spy.clearCalled == false)
  }

  // Malformed Link header -> pagination stops after page 1, items returned.
  @Test func paginatedMalformedLinkHeaderTerminatesSinglePage() async {
    StubURLProtocol.reset()
    let pageURL = "\(apiBase)orgs/test/actions/runners"
    StubURLProtocol.register(.init( jsonPage([["id": "1", "name": "runner-a"]]), statusCode: 200, headers: ["Link": "not-a-url; rel=next"]), for: pageURL)
    let spy = SpyRateLimitActor()
    let transport = GitHubTransport(session: stubSession, rateLimiter: spy, tokenProvider: { "test-token" })
    let result = await transport.apiPaginated("/orgs/test/actions/runners")
    #expect(result != nil)
    #expect(decodeItems(result)?.count == 1)
    #expect(await spy.setCalled == false)
    #expect(await spy.clearCalled == true)
  }
}
