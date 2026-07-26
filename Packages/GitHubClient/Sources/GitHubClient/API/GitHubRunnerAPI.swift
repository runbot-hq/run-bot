// GitHubRunnerAPI.swift
// GitHubClient

import Foundation

// MARK: - Models

/// A GitHub Actions self-hosted runner as returned by the REST API.
public struct GitHubRunner: Codable, Identifiable, Sendable, Equatable {
    /// Unique numeric runner ID assigned by GitHub.
    public let id: Int
    /// Display name of the runner (e.g. `"my-mac-runner"`).
    public let name: String
    /// Raw status string from the API: `"online"`, `"offline"`, or `"busy"`.
    /// RunBotCore is responsible for interpreting this value via `runnerStatus`.
    public let status: String
    /// `true` when the runner is actively executing a job.
    public let busy: Bool
    /// Labels attached to this runner.
    public let labels: [GitHubRunnerLabel]
}

/// A label attached to a GitHub Actions self-hosted runner.
public struct GitHubRunnerLabel: Codable, Sendable, Equatable {
    /// Unique numeric label ID assigned by GitHub.
    public let id: Int
    /// Display name of the label (e.g. `"self-hosted"`, `"macOS"`).
    public let name: String
    /// The label type as returned by the API: `"read-only"` for system labels, `"custom"` for user-defined labels.
    public let type: String
}

// MARK: - API

/// Fetches all registered runners for a scope. Follows pagination automatically.
///
/// `apiPaginated` returns a flat JSON array encoded as `Data`. This function decodes
/// that directly as `[GitHubRunner]` — **not** via a `{"runners":[...]}` wrapper.
/// The GitHub REST API wraps runners in a `runners` key, but `apiPaginated` strips the
/// envelope and returns only the array items, so no wrapper is needed here.
///
/// - Parameters:
///   - scope: The org or repo scope to query.
///   - transport: The network transport to use. Defaults to `currentTransport`
///     (wired at launch by `GitHubClient.init`). Pass a mock in tests.
@concurrent
public func fetchRunners(
    scope: Scope,
    transport: any GitHubTransportProtocol = currentTransport
) async -> [GitHubRunner] {
    let endpoint = "\(scope.apiPrefix)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
    guard let data = await transport.apiPaginated(endpoint) else { return [] }
    // apiPaginated returns a flat JSON array — decode directly as [GitHubRunner].
    // Do NOT use a {"runners":[...]} wrapper here: apiPaginated strips the
    // GitHub API envelope and encodes only the array items into the returned Data.
    do {
        return try transport.decoder.decode([GitHubRunner].self, from: data)
    } catch {
        transport.logger?.log(
            "fetchRunners › decode failed for scope=\(scope.apiPrefix): \(error)",
            category: "transport"
        )
        return []
    }
}

/// Convenience overload — parses `scopeString` first, returns `nil` on invalid input.
///
/// - Parameters:
///   - scopeString: A scope string such as `"orgs/acme"` or `"repos/acme/my-repo"`.
///   - transport: The network transport to use. Defaults to `currentTransport`.
///     Threaded through to `fetchRunners(scope:transport:)`.
@concurrent
public func fetchRunners(
    scopeString: String,
    transport: any GitHubTransportProtocol = currentTransport
) async -> [GitHubRunner]? {
    // `nil` return on parse failure is intentional — an unparseable scopeString is a
    // caller programming error, not a runtime or network failure. No log is emitted
    // here by design: the `nil` return is the signal that forces the caller to handle
    // the bad input. Compare with the decode/network failures in fetchRunners(scope:)
    // above, which are runtime conditions and do warrant a log.
    guard let scope = Scope.parse(scopeString) else { return nil }
    return await fetchRunners(scope: scope, transport: transport)
}
