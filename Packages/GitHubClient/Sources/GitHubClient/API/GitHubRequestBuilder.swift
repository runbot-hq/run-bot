// GitHubRequestBuilder.swift
// GitHubClient
import Foundation

/// Characters to strip when trimming leading and trailing slashes from endpoint strings.
private let slashCharacterSet = CharacterSet(charactersIn: "/")

// MARK: - URL helpers

/// Resolves an endpoint string to a full GitHub API URL string.
public func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http") ? endpoint : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
}

// MARK: - Request factories

/// Builds a `URLRequest` with the Authorization and API-version headers shared by all GitHub REST calls.
private func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github+json` Accept header.
public func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github.v3.raw` Accept header.
/// Used for log and raw-file endpoints that redirect to S3.
/// `URLSession` follows the redirect automatically and the Accept header is preserved,
/// so the S3 response body is the raw bytes rather than a JSON envelope.
public func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}
