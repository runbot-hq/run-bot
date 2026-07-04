// GitHubRunnerAPI.swift
// GitHubClient

import Foundation

// MARK: - Models

/// A GitHub Actions self-hosted runner as returned by the REST API.
public struct GitHubRunner: Codable, Identifiable, Sendable, Equatable {
    public let id: Int
    public let name: String
    /// Raw status string from the API: `"online"`, `"offline"`, or `"busy"`.
    /// RunBotCore is responsible for interpreting this value via `runnerStatus`.
    public let status: String
    public let busy: Bool
    public let labels: [GitHubRunnerLabel]

    /// The label name strings for this runner (e.g. `["self-hosted", "macOS", "arm64"]`).
    public var labelNames: [String] { labels.map(\.name) }
}

/// A label attached to a GitHub Actions self-hosted runner.
public struct GitHubRunnerLabel: Codable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let type: String
}

// MARK: - API

/// Fetches all registered runners for a scope. Follows pagination automatically.
@concurrent
public func fetchRunners(scope: Scope) async -> [GitHubRunner] {
    let endpoint = "\(scope.apiPrefix)/actions/runners?per_page=\(GitHubConstants.maxPageSize)"
    guard let data = await ghAPIPaginated(endpoint) else { return [] }
    struct Response: Decodable { let runners: [GitHubRunner] }
    return (try? JSONDecoder().decode(Response.self, from: data))?.runners ?? []
}

/// Convenience overload — parses `scopeString` first, returns `nil` on invalid input.
@concurrent
public func fetchRunners(scopeString: String) async -> [GitHubRunner]? {
    guard let scope = Scope.parse(scopeString) else { return nil }
    return await fetchRunners(scope: scope)
}
