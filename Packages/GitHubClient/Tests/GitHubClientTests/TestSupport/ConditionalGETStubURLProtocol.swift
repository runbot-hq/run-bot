// ConditionalGETStubURLProtocol.swift
// GitHubClientTests
//
// Dedicated URLProtocol stub for conditional GET tests. Uses its own static
// registry so tests in ConditionalGETTransportTests never interfere with
// TransportIncrementGuard (APICallCounterTests) — both suites use the same
// IsolatedStubURLProtocol pattern but with separate storage.
//

import Foundation

/// A `URLProtocol` stub with its own static registry, used exclusively by
/// `ConditionalGETTransportTests` to avoid registry collisions with
/// `TransportIncrementGuard` (which uses `IsolatedStubURLProtocol`).
///
/// - Note: Both suites use `IsolatedStubURLProtocol` as the base pattern, but
///   `IsolatedStubURLProtocol`'s registry is process-global. This class provides
///   an independent registry so the two suites can run concurrently without
///   interfering with each other's stubs.
final class ConditionalGETStubURLProtocol: URLProtocol, @unchecked Sendable {

  /// A stub response definition.
  struct Stub {
    /// The response body data.
    let data: Data
    /// The HTTP status code.
    let statusCode: Int
    /// The HTTP response headers.
    let headers: [String: String]
  }

  /// Lock for synchronising access to the static registries.
  private static let lock = NSLock()
  /// URL-to-stub mapping for successful responses.
  nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

  /// Register a successful response stub for the given URL.
  static func register(_ stub: Stub, for url: String) {
    lock.withLock { stubs[url] = stub }
  }

  /// Clear all registered stubs.
  static func reset() {
    lock.withLock { stubs = [:] }
  }

  override static func canInit(with request: URLRequest) -> Bool {
    let key = request.url?.absoluteString ?? ""
    return lock.withLock { stubs[key] != nil }
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Records the last request URL that was loaded (for header inspection).
  nonisolated(unsafe) private static var lastRequestedURL: String?
  /// Records the headers of the last request that was loaded.
  nonisolated(unsafe) private static var lastRequestHeaders: [String: String]?

  /// Returns the last request URL and headers, if any.
  static func lastRequest() -> (url: String, headers: [String: String])? {
    lock.withLock {
      guard let url = lastRequestedURL, let headers = lastRequestHeaders else { return nil }
      return (url, headers)
    }
  }

  /// Clears the recorded last request.
  static func resetLastRequest() {
    lock.withLock {
      lastRequestedURL = nil
      lastRequestHeaders = nil
    }
  }

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    ConditionalGETStubURLProtocol.lock.withLock {
      ConditionalGETStubURLProtocol.lastRequestedURL = key
      ConditionalGETStubURLProtocol.lastRequestHeaders = request.allHTTPHeaderFields
    }
    guard let stub = ConditionalGETStubURLProtocol.lock.withLock(
      { ConditionalGETStubURLProtocol.stubs[key] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    deliverStubbedResponse(data: stub.data, statusCode: stub.statusCode, headerFields: stub.headers)
  }

  override func stopLoading() {
    // Intentionally empty: stubbed URL protocol has no real load to stop.
  }
}
