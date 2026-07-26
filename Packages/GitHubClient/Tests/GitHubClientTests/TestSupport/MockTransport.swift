// MockTransport.swift
// GitHubClientTests
//
// Controllable stub conforming to GitHubTransportProtocol for use in unit tests.
// Every method delegates to a closure property that defaults to a safe no-op.
// Tests override only the closures they need.

import Foundation
@testable import GitHubClient

// MARK: - MockTransport

/// A test double for `GitHubTransportProtocol`.
///
/// Each method has a corresponding `on<MethodName>` closure that the test
/// controls. Defaults are safe: `nil` for data-returning methods, `false`
/// for bool-returning methods.
final class MockTransport: GitHubTransportProtocol, @unchecked Sendable {

    // MARK: - Controllable closures

    var onApiAsync: (String, TimeInterval) async -> Data? = { _, _ in nil }
    var onApiPaginated: (String, TimeInterval) async -> Data? = { _, _ in nil }
    var onRaw: (String, TimeInterval) async -> Data? = { _, _ in nil }
    var onPost: (String, Data?, TimeInterval) async -> Data? = { _, _, _ in nil }
    var onPut: (String, Data, TimeInterval) async -> Data? = { _, _, _ in nil }
    var onDelete: (String, TimeInterval) async -> Bool = { _, _ in false }
    var onCancelRun: (Int, String) async -> Bool = { _, _ in false }
    var onPatchRunnerLabels: (String, Int, [String]) async -> [String]? = { _, _, _ in nil }
    var onFetchRegistrationToken: (String) async -> String? = { _ in nil }
    var onFetchRemovalToken: (String) async -> String? = { _ in nil }
    var onDeleteRunnerByID: (String, Int) async -> Bool = { _, _ in false }

    // MARK: - Spy state

    private(set) var cancelRunCalls: [(runID: Int, scope: String)] = []
    private(set) var apiAsyncEndpoints: [String] = []

    // MARK: - GitHubTransportProtocol

    /// Intentionally returns a **fresh** `JSONDecoder()` on each access, which
    /// deviates from the same-instance convention documented on
    /// `GitHubTransportProtocol.decoder`. This is safe for mock use because
    /// `MockTransport` returns pre-encoded `Data` fixtures that are produced
    /// without any custom key or date strategy — so every call decodes correctly
    /// with a plain default decoder. If a future test requires a custom strategy
    /// (e.g. a `keyDecodingStrategy`), it must either subclass `MockTransport`
    /// and override `decoder`, or switch to a real `GitHubTransport` configured
    /// with the desired strategy.
    var decoder: JSONDecoder { JSONDecoder() }
    var logger: (any GitHubLogger)? { nil }

    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        apiAsyncEndpoints.append(endpoint)
        return await onApiAsync(endpoint, timeout)
    }

    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        await onApiPaginated(endpoint, timeout)
    }

    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data? {
        await onRaw(endpoint, timeout)
    }

    func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data? {
        await onPost(endpoint, body, timeout)
    }

    func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data? {
        await onPut(endpoint, body, timeout)
    }

    func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool {
        await onDelete(endpoint, timeout)
    }

    func cancelRun(runID: Int, scope: String) async -> Bool {
        cancelRunCalls.append((runID, scope))
        return await onCancelRun(runID, scope)
    }

    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        await onPatchRunnerLabels(scope, runnerID, labels)
    }

    func fetchRegistrationToken(scope: String) async -> String? {
        await onFetchRegistrationToken(scope)
    }

    func fetchRemovalToken(scope: String) async -> String? {
        await onFetchRemovalToken(scope)
    }

    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool {
        await onDeleteRunnerByID(scope, runnerID)
    }
}
