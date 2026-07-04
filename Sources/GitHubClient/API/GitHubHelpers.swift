// GitHubHelpers.swift
// GitHubClient
import Foundation
import os

// MARK: - User orgs and repos

public func fetchUserOrgs() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userOrgsPath)?per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    struct Org: Decodable { let login: String }
    guard let orgs = try? JSONDecoder().decode([Org].self, from: data) else { return [] }
    return orgs.map(\.login)
}

public func fetchUserRepos() async -> [String] {
    guard let data = await ghAPIPaginated("\(GitHubConstants.userReposPath)?sort=updated&per_page=\(GitHubConstants.maxPageSize)") else { return [] }
    struct Repo: Decodable {
        let fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    guard let repos = try? JSONDecoder().decode([Repo].self, from: data) else { return [] }
    return repos.map(\.fullName)
}

// MARK: - Step log

private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

@concurrent
public func fetchStepLog(jobID: Int, stepNumber: Int, scope scopeString: String) async -> String? {
    guard let scope = Scope.parse(scopeString) else {
        log("fetchStepLog › invalid scope: \(scopeString)", category: .transport)
        return nil
    }
    guard case .repo = scope else {
        log("fetchStepLog › skipped: org-scoped logs not supported (scope=\(scopeString))", category: .transport)
        return nil
    }
    let endpoint = "\(scope.apiPrefix)/actions/jobs/\(jobID)/logs"
    log("fetchStepLog › fetching \(endpoint) step=\(stepNumber)", category: .transport)
    guard let raw = await fetchAndDecodeStepLog(endpoint: endpoint, jobID: jobID) else { return nil }
    return parseStepLog(raw, stepNumber: stepNumber)
}

@concurrent
private func fetchAndDecodeStepLog(endpoint: String, jobID: Int) async -> String? {
    guard let data = await urlSessionRaw(endpoint) else {
        log("fetchStepLog › urlSessionRaw returned nil for job \(jobID)", category: .transport)
        return nil
    }
    guard let raw = String(data: data, encoding: .utf8) else {
        log("fetchStepLog › UTF-8 decode failed for job \(jobID) (\(data.count) bytes)", category: .transport)
        return nil
    }
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("fetchStepLog › empty body for job \(jobID)", category: .transport)
        return nil
    }
    if raw.hasPrefix("{") {
        log("fetchStepLog › error JSON returned: \(raw.prefix(120))", category: .transport)
        return nil
    }
    return raw
}

private func parseStepLog(_ raw: String, stepNumber: Int) -> String? {
    let cleaned = stripAnsi(raw)
    let sections = buildLogSections(from: cleaned)
    log("parseStepLog › parsed \(sections.count) section(s) from log", category: .transport)
    if sections.isEmpty {
        log("parseStepLog › no group markers, returning full raw log", category: .transport)
        return cleaned
    }
    let index = stepNumber - 1
    guard index >= 0, index < sections.count else {
        log(
            "parseStepLog › stepNumber \(stepNumber) out of range "
                + "(sections=\(sections.count)), returning full log",
            category: .transport
        )
        return cleaned
    }
    let section = sections[index]
    log("parseStepLog › step \(stepNumber) → \(section.count)ch", category: .transport)
    return section
}

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

private func stripAnsi(_ input: String) -> String {
    guard let ansiRegex else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return ansiRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}
