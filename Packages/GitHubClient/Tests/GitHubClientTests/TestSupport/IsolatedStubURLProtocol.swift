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

  override func startLoading() {
    let key = request.url?.absoluteString ?? ""
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
