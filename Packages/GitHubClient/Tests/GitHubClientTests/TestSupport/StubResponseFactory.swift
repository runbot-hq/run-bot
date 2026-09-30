// StubResponseFactory.swift
// GitHubClient

import Foundation

extension URLProtocol {
    /// Delivers `data` as a successful stubbed HTTP response for this
    /// protocol's own request, then finishes loading.
    ///
    /// Reports `URLError(.badServerResponse)` via `didFailWithError` when the
    /// response cannot be constructed — never returns silently, which would
    /// leave the session request unresolved until timeout.
    func deliverStubbedResponse(
        data: Data,
        statusCode: Int,
        headerFields: [String: String]?
    ) {
        guard let client else { return }
        let response = request.url.flatMap {
            HTTPURLResponse(
                url: $0,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headerFields)
        }
        guard let response else {
            client.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }
}
