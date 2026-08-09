import Foundation

final class IsolatedStubURLProtocol: URLProtocol, @unchecked Sendable {
  struct Stub {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
  }
  struct ErrorStub { let error: URLError }

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
    lock.withLock { stubs = [:]; errorStubs = [:] }
  }

  override class func canInit(with request: URLRequest) -> Bool {
    let key = request.url?.absoluteString ?? ""
    return lock.withLock { stubs[key] != nil || errorStubs[key] != nil }
  }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  /// Records the last request URL that was loaded (for header inspection).
  nonisolated(unsafe) private static var lastRequestedURL: String?
  /// Records the headers of the last request that was loaded.
  nonisolated(unsafe) private static var lastRequestHeaders: [String: String]?

  static func lastRequest() -> (url: String, headers: [String: String])? {
    lock.withLock {
      guard let url = lastRequestedURL, let headers = lastRequestHeaders else { return nil }
      return (url, headers)
    }
  }

  static func resetLastRequest() {
    lock.withLock {
      lastRequestedURL = nil
      lastRequestHeaders = nil
    }
  }

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
    IsolatedStubURLProtocol.lock.withLock {
      IsolatedStubURLProtocol.lastRequestedURL = key
      IsolatedStubURLProtocol.lastRequestHeaders = request.allHTTPHeaderFields
    }
    if let e = IsolatedStubURLProtocol.lock.withLock(
      { IsolatedStubURLProtocol.errorStubs[key] }) {
      client?.urlProtocol(self, didFailWithError: e.error)
      return
    }
    guard let stub = IsolatedStubURLProtocol.lock.withLock(
      { IsolatedStubURLProtocol.stubs[key] })
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
      return
    }
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: stub.statusCode,
      httpVersion: "HTTP/1.1",
      headerFields: stub.headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: stub.data)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}
