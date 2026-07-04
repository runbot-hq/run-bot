// GitHubTransportProtocol.swift
// GitHubClient

import Foundation

// MARK: - Transport protocol

/// Protocol describing the full set of GitHub network operations performed by
/// `GitHubTransport`. Conforming types can be injected in place of the real
/// `URLSession`-backed implementation, enabling unit tests to run without
/// network access.
///
/// - Note: All methods mirror the existing free-function signatures in this file.
///   Default `timeout` values match the legacy free-function defaults so that
///   existing call sites require no changes when migrated.
public protocol GitHubTransportProtocol: Sendable {
    /// Fetches a single GitHub REST API page. Returns decoded `Data` on success, `nil` on any failure.
    @concurrent
    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Fetches and concatenates all pages for a paginated GitHub REST endpoint.
    @concurrent
    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Fetches raw bytes (e.g. log files) following redirects. Returns `nil` on failure.
    @concurrent
    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data?
    /// Posts `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    @discardableResult
    func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data?
    /// Sends a PUT with `body` to `endpoint`. Returns decoded response `Data`, or `nil` on failure.
    @concurrent
    func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data?
    /// Sends a DELETE to `endpoint`. Returns `true` on 2xx, `false` otherwise.
    @concurrent
    @discardableResult
    func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool
    /// Cancels the workflow run identified by `runID` inside `scope`.
    @concurrent
    func cancelRun(runID: Int, scope: String) async -> Bool
    /// Replaces the labels on `runnerID` within `scope`. Returns the updated label list, or `nil`.
    @concurrent
    @discardableResult
    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]?
    /// Fetches a short-lived registration token for the runner identified by `scope`.
    @concurrent
    func fetchRegistrationToken(scope: String) async -> String?
    /// Fetches a short-lived removal token for the runner identified by `scope`.
    @concurrent
    func fetchRemovalToken(scope: String) async -> String?
    /// Removes the runner identified by `runnerID` from `scope`. Returns `true` on success.
    @concurrent
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool
}

// MARK: - GitHubTransportProtocol defaults

/// Timeout-free convenience overloads for all protocol methods.
public extension GitHubTransportProtocol {
    func apiAsync(_ endpoint: String) async -> Data? {
        await apiAsync(endpoint, timeout: 20)
    }
    func apiPaginated(_ endpoint: String) async -> Data? {
        await apiPaginated(endpoint, timeout: 60)
    }
    func raw(_ endpoint: String) async -> Data? {
        await raw(endpoint, timeout: 60)
    }
    func post(_ endpoint: String, body: Data? = nil) async -> Data? {
        await post(endpoint, body: body, timeout: 30)
    }
    func put(_ endpoint: String, body: Data) async -> Data? {
        await put(endpoint, body: body, timeout: 30)
    }
    func delete(_ endpoint: String) async -> Bool {
        await delete(endpoint, timeout: 30)
    }
}
