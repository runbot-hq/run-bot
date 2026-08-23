// StubResponseFactory.swift
// GitHubClient

import Foundation

/// Builds an `HTTPURLResponse` for a stubbed URL request.
///
/// Shared by the test `URLProtocol` stubs so response construction lives in
/// exactly one place. Returns `nil` when `url` cannot be resolved or the
/// response cannot be constructed — callers treat that as a failed stub hit.
func makeStubResponse(
    url: URL?,
    statusCode: Int,
    headerFields: [String: String]?
) -> HTTPURLResponse? {
    guard let url else { return nil }
    return HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headerFields
    )
}
