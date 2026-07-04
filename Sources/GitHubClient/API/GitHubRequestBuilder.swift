// GitHubRequestBuilder.swift
// GitHubClient

import Foundation

/// Module-level constant allocated once; avoids a fresh `CharacterSet` allocation
/// on every `resolveURL` call and pagination iteration.
private let slashCharacterSet = CharacterSet(charactersIn: "/")

// MARK: - URL helpers

/// Resolves an endpoint string to a full GitHub API URL string.
/// Absolute URLs (starting with "http") are returned unchanged;
/// relative paths are prefixed with `GitHubConstants.apiBase`.
public func resolveURL(_ endpoint: String) -> String {
    endpoint.hasPrefix("http")
        ? endpoint
        : "\(GitHubConstants.apiBase)/\(endpoint.trimmingCharacters(in: slashCharacterSet))"
}

// MARK: - Request factories

/// Builds a `URLRequest` with the headers common to all GitHub API requests:
/// `Authorization: Bearer`, `X-GitHub-Api-Version`.
/// Only called by `makeRequest` and `makeRawRequest` in this file.
private func makeBaseRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = URLRequest(url: url, timeoutInterval: timeout)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
    return req
}

/// Builds a pre-configured `URLRequest` with the standard `application/vnd.github+json` Accept header.
public func makeRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    return req
}

/// Builds a `URLRequest` with the `application/vnd.github.v3.raw` Accept header.
/// Used for log endpoints that 302-redirect to raw S3 content.
///
/// # S3 redirect safety
/// The `Authorization: Bearer` header is sent only to api.github.com.
/// Apple's URLSession strips it before following a cross-origin redirect
/// (RFC 7235 / Apple URLSession behaviour), so the Bearer token is never
/// forwarded to S3. No custom redirect delegate is required.
public func makeRawRequest(url: URL, token: String, timeout: TimeInterval) -> URLRequest {
    var req = makeBaseRequest(url: url, token: token, timeout: timeout)
    req.setValue("application/vnd.github.v3.raw", forHTTPHeaderField: "Accept")
    return req
}
