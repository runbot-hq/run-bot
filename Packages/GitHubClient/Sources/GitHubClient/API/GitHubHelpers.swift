// GitHubHelpers.swift
// GitHubClient
import Foundation
import os

// MARK: - User orgs and repos

/// Returns the login names of all GitHub organisations the authenticated user belongs to.
@concurrent
public func fetchUserOrgs(
    transport: any GitHubTransportProtocol = currentTransport
) async -> [String] {
    guard let data = await transport.apiPaginated(
        "\(GitHubConstants.userOrgsPath)?per_page=\(GitHubConstants.maxPageSize)"
    ) else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Returns the `owner/repo` full names of all repositories visible to the authenticated user.
@concurrent
public func fetchUserRepos(
    transport: any GitHubTransportProtocol = currentTransport
) async -> [String] {
    guard let data = await transport.apiPaginated(
        "\(GitHubConstants.userReposPath)?sort=updated&per_page=\(GitHubConstants.maxPageSize)"
    ) else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

/// Pre-compiled regular expression for stripping ANSI escape sequences from CI log output.
/// Compiled once at module load to avoid repeated allocation on every log fetch.
private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

/// Fetches the log for a single step via the transport layer's `raw()` method.
@concurrent
public func fetchStepLog(
    jobID: Int,
    stepNumber: Int,
    scope scopeString: String,
    transport: any GitHubTransportProtocol = currentTransport
) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        transport.logger?.log("fetchStepLog › invalid scope: \(scopeString)", category: "transport")
        return nil
    }
    guard case .repo = scope else {
        transport.logger?.log(
            "fetchStepLog › skipped: org-scoped logs not supported (scope=\(scopeString))",
            category: "transport")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/jobs/\(jobID)/logs"
    transport.logger?.log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)", category: "transport")
    guard let raw = await fetchAndDecodeStepLog(endpoint: endpoint, jobID: jobID, transport: transport) else {
        return nil
    }
    return parseStepLog(raw, stepNumber: stepNumber, logger: transport.logger)
}

/// Fetches raw log bytes from `endpoint` and decodes them as UTF-8.
/// GitHub’s log endpoint redirects to S3; `URLSession` follows the redirect automatically
/// and returns the raw log text. A response body starting with `{` indicates a GitHub
/// error object was returned instead of log content and is treated as a failure.
@concurrent
private func fetchAndDecodeStepLog(
    endpoint: String,
    jobID: Int,
    transport: any GitHubTransportProtocol
) async -> String? {
    guard let data = await transport.raw(endpoint) else {
        transport.logger?.log("fetchStepLog › raw returned nil for job \(jobID)", category: "transport")
        return nil
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        transport.logger?.log(
            "fetchStepLog › UTF-8 decode failed for job \(jobID) (\(data.count) bytes)",
            category: "transport")
        return nil
    }
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        transport.logger?.log("fetchStepLog › empty body for job \(jobID)", category: "transport")
        return nil
    }
    if raw.hasPrefix("{") {
        transport.logger?.log("fetchStepLog › error JSON returned: \(raw.prefix(120))", category: "transport")
        return nil
    }
    return raw
}

/// Extracts the log section for `stepNumber` from a raw multi-group log string.
/// If the log contains no `##[group]` markers the full cleaned log is returned.
/// If `stepNumber` is out of range the full cleaned log is returned as a fallback.
private func parseStepLog(
    _ raw: String,
    stepNumber: Int,
    logger: (any GitHubLogger)?
) -> String? {
    let cleaned = stripAnsi(raw)
    let sections = buildLogSections(from: cleaned)
    logger?.log("parseStepLog › parsed \(sections.count) section(s) from log", category: "transport")
    if sections.isEmpty {
        logger?.log("parseStepLog › no group markers, returning full raw log", category: "transport")
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        logger?.log(
            "parseStepLog › stepNumber \(stepNumber) out of range "
            + "(sections=\(sections.count)), returning full log",
            category: "transport")
        return cleaned
    }
    let section = sections[index]
    logger?.log("parseStepLog › step \(stepNumber) → \(section.count)ch", category: "transport")
    return section
}

/// Splits a cleaned log string into sections delimited by `##[group]` markers.
/// Each section starts at the marker line and ends just before the next marker.
private func buildLogSections(from cleaned: String) -> [String] {
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []
    var seenGroup = false
    for line in lines {
        if line.contains("##[group]") {
            if seenGroup, !current.isEmpty { sections.append(current.joined(separator: "\n")) }
            seenGroup = true
            current = [line]
        } else if seenGroup {
            current.append(line)
        }
    }
    if seenGroup, !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    return sections
}

/// Removes ANSI escape sequences from `input` using the pre-compiled `ansiRegex`.
/// Returns `input` unchanged if `ansiRegex` failed to compile at module load time.
private func stripAnsi(_ input: String) -> String {
    guard let ansiRegex else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return ansiRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}
