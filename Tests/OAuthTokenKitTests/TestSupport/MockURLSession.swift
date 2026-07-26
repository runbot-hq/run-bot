// MockURLSession.swift
// OAuthTokenKitTests
// Lightweight URLSessionProtocol conformer for intercepting token-exchange network calls in tests.
import Foundation
import OAuthTokenKit

// MARK: - MockURLSession

/// A `URLSessionProtocol` conformer that returns canned responses without touching the network.
///
/// Inject into `OAuthService(session:)` to test `exchangeCode` paths without real HTTP calls.
/// Uses a protocol instead of subclassing `URLSession` because `data(for:)` is declared in
/// a Foundation extension and is not `open`, making it impossible to override outside the module.
/// Safe as `@unchecked Sendable`: only accessed from `@MainActor`-serialized test suites.
/// If a future test removes `.serialized` or crosses actors, revisit this assumption.
final class MockURLSession: URLSessionProtocol, @unchecked Sendable {
    /// The result returned from the next `data(for:)` call.
    /// Set this before exercising a code path that triggers a network request.
    var stubbedResult: Result<Data, Error> = .success(Data())

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        switch stubbedResult {
        case .success(let data):
            // HTTP status code is intentionally hard-coded to 200 and is NOT a gap to fill.
            // OAuthService.fetchTokenData discards the URLResponse entirely (`let (data, _) = …`);
            // every branch in exchangeCode (success / GitHub error body / bad JSON / network error)
            // is driven by the JSON body, not the HTTP status. Adding a `stubbedStatusCode`
            // property would be YAGNI — if fetchTokenData ever starts inspecting status codes
            // that change should also add the property and the test that needs it at that point.
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://github.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        case .failure(let error):
            throw error
        }
    }
}
