// GitHubTransportETagTests.swift
// GitHubClientTests

import Foundation
import Testing
@testable import GitHubClient

@Suite("GitHubTransport ETag", .serialized)
final class GitHubTransportETagTests {

  private let stubSession: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
  }()

  private func makeTransport(counter: MockAPICallCounter = MockAPICallCounter()) -> GitHubTransport {
    GitHubTransport(session: stubSession, tokenProvider: { "test-token" }, callCounter: counter)
  }

  // 200 with ETag header → stored in cache.
  @Test
  func execute_200_storesETagInCache() async {
    StubURLProtocol.reset()
    let url = GitHubConstants.apiBase + "/repos/owner/repo/actions/runs"
    let body = Data("[{\"id\":1}]".utf8)
    StubURLProtocol.register(.init( body, statusCode: 200, headers: ["ETag": "\"etag-v1\""]), for: url)
    let cache = ETagCache()
    _ = await makeTransport().execute(url, timeout: 10, logTag: "test", etagCache: cache)
    #expect(await cache.etag(for: url) == "\"etag-v1\"")
    #expect(await cache.data(for: url) == body)
  }

  // 304 → returns cached body, does NOT increment call counter.
  @Test
  func execute_304_returnsCachedData_andDoesNotIncrementCounter() async {
    StubURLProtocol.reset()
    let url = GitHubConstants.apiBase + "/repos/owner/repo/actions/runs"
    let cachedBody = Data("[{\"id\":42}]".utf8)
    StubURLProtocol.register(.init( Data(), statusCode: 304, headers: [:]), for: url)
    let cache = ETagCache()
    await cache.store(url: url, etag: "\"etag-v1\"",  cachedBody)
    let counter = MockAPICallCounter()
    let result = await makeTransport(counter: counter).execute(url, timeout: 10, logTag: "test", etagCache: cache)
    guard case .notModified(let returned) = result else {
      Issue.record("Expected .notModified, got \(result)")
      return
    }
    #expect(returned == cachedBody)
    #expect(await counter.recordedCount == 0)
  }
}
