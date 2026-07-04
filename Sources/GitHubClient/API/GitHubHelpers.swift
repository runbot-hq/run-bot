// GitHubHelpers.swift
// GitHubClient
import Foundation
import os

// MARK: - URL helpers

// MARK: - User orgs and repos

/// Returns the login names of all GitHub organisations the authenticated user belongs to.
public func fetchUserOrgs() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userOrgsPath)?per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    struct Org: Decodable {
        let login: String
    }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

/// Returns the `owner/repo` full names of all repositories visible to the authenticated user.
public func fetchUserRepos() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userReposPath)?sort=updated&per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey {
            case fullName = "full_name"
        }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

/// Precompiled regex matching ANSI escape sequences, stripped from step logs.
private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

/// Fetches the log for a single step via the transport layer's `urlSessionRaw()`.
@concurrent
public func fetchStepLog(jobID: Int, stepNumber: Int, scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        sharedGitHubTransport.logger?.log("fetchStepLog › invalid scope: \(scopeString)", category: "transport")
        return nil
    }
    guard case .repo = scope else {
        sharedGitHubTransport.logger?.log(
            "fetchStepLog › skipped: org-scoped logs not supported (scope=\(scopeString))",
            category: "transport")
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/jobs/\(jobID)/logs"
    sharedGitHubTransport.logger?.log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)", category: "transport")
    guard let raw = await fetchAndDecodeStepLog(endpoint: endpoint, jobID: jobID) else { return nil }
    return parseStepLog(raw, stepNumber: stepNumber)
}

/// Fetches raw log bytes for `endpoint` and decodes them as UTF-8 text, or `nil` on failure.
@concurrent
private func fetchAndDecodeStepLog(endpoint: String, jobID: Int) async -> String? {
    guard let data = await urlSessionRaw(endpoint) else {
        sharedGitHubTransport.logger?.log("fetchStepLog › urlSessionRaw returned nil for job \(jobID)", category: "transport")
        return nil
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        sharedGitHubTransport.logger?.log(
            "fetchStepLog › UTF-8 decode failed for job \(jobID) (\(data.count) bytes)",
            category: "transport")
        return nil
    }
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        sharedGitHubTransport.logger?.log("fetchStepLog › empty body for job \(jobID)", category: "transport")
        return nil
    }
    if raw.hasPrefix("{") {
        sharedGitHubTransport.logger?.log("fetchStepLog › error JSON returned: \(raw.prefix(120))", category: "transport")
        return nil
    }
    return raw
}

/// Strips ANSI codes and returns the log section for `stepNumber` (1-based), or the whole log.
private func parseStepLog(_ raw: String, stepNumber: Int) -> String? {
    let cleaned = stripAnsi(raw)
    let sections = buildLogSections(from: cleaned)
    sharedGitHubTransport.logger?.log("parseStepLog › parsed \(sections.count) section(s) from log", category: "transport")
    if sections.isEmpty {
        sharedGitHubTransport.logger?.log("parseStepLog › no group markers, returning full raw log", category: "transport")
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        sharedGitHubTransport.logger?.log(
            "parseStepLog › stepNumber \(stepNumber) out of range "
                + "(sections=\(sections.count)), returning full log",
            category: "transport")
        return cleaned
    }
    let section = sections[index]
    sharedGitHubTransport.logger?.log("parseStepLog › step \(stepNumber) → \(section.count)ch", category: "transport")
    return section
}

/// Splits cleaned log text into sections delimited by `##[group]` markers.
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

/// Removes ANSI escape sequences from `input` using the precompiled `ansiRegex`.
private func stripAnsi(_ input: String) -> String {
    guard let ansiRegex else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return ansiRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}
