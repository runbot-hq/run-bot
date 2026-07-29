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

// References — ANSI stripping:
// • laurent22/github-actions-logs-extension (Chrome/Firefox extension, converts ANSI to HTML colours):
//   https://github.com/laurent22/github-actions-logs-extension
// • Joplin blog — walkthrough of the extension and why raw Actions logs need client-side parsing:
//   https://joplinapp.org/news/20230116-github-actions-log-viewer/

/// Pre-compiled regular expression for stripping ANSI escape sequences from CI log output.
/// Compiled once at module load to avoid repeated allocation on every log fetch.
///
/// `try?` is intentional: the pattern is a static literal and will never fail to compile
/// at runtime. The `try?` form is consistent with `timestampRegex` below and avoids a
/// forced-unwrap that would crash on launch for a non-fatal feature. If compilation somehow
/// fails, `stripAnsi` falls back to returning input unchanged — logs remain readable, just
/// with ANSI codes present. This is the correct degradation behaviour.
///
/// Note: `stripAnsi` must run **after** CR normalisation (step 2 in `parseStepLog`) and
/// **before** `stripTimestamps`. The ANSI pattern is character-based and does not interact
/// with line endings, but maintaining the documented pipeline order is required for
/// `stripTimestamps` to receive clean LF-only input.
private let ansiRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[A-Za-z]"
)

// References — timestamp stripping:
// • ncw/parse-actions-logs (Go CLI, functionally identical regex with optional fractional seconds):
//   https://github.com/ncw/parse-actions-logs
// • Xebia — Fluentd/regex approach to stripping the RFC3339 prefix for log forwarding:
//   https://xebia.com/blog/how-to-forward-github-action-runner-logs/
// • GitHub Community — Promtail pipeline with RFC3339Nano timestamp extraction:
//   https://github.com/orgs/community/discussions/160683
// • GitHub REST API — fetching raw log bytes via GET /repos/.../actions/jobs/{job_id}/logs:
//   https://www.getorchestra.io/guides/github-actions-download-job-logs-for-a-workflow-ru

/// Pre-compiled regular expression for stripping GitHub Actions log timestamp prefixes.
/// Every line from the Actions log API is prefixed with an ISO 8601 timestamp + optional space,
/// e.g. `2026-07-29T03:11:15.4722230Z ` (content line) or `2026-07-29T03:11:15.0000000Z` (blank line).
///
/// **Fractional seconds (`\.\d+`)?** — The group is optional (`?`) to cover whole-second
/// timestamps (e.g. `2026-07-29T03:11:15Z`) that self-hosted or future runners may emit.
/// The digit count is intentionally **not** constrained to `{1,6}` or `{1,9}`: GitHub Actions
/// currently emits 7-digit precision and some runners emit nanoseconds; constraining the
/// digit count would silently fail to strip valid prefixes on those runners. This matches
/// the approach taken by ncw/parse-actions-logs and other reference implementations.
///
/// **Trailing `[^\S\n]*`** — Matches zero or more non-newline whitespace characters
/// (spaces, tabs, and any other Unicode whitespace except `\n`) after the Z. This serves
/// two purposes: (1) it consumes the single space separator that GitHub Actions emits
/// between the timestamp and the log content; (2) it tolerates the ANSI-after-Z case
/// where `stripAnsi` has already removed an escape sequence that sat between Z and the
/// space, leaving Z immediately adjacent to the content with no intervening space.
/// Tabs after Z are therefore also matched — this is intentional and future-proof.
/// Bare timestamp-only lines (no trailing whitespace at all) are matched via the `*`
/// (zero repetitions).
///
/// **`try?`** — Intentional; see note on `ansiRegex` above. Same degradation contract:
/// if compilation fails, `stripTimestamps` returns input unchanged.
///
/// Compiled once at module load.
private let timestampRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z[^\S\n]*"#,
    options: .anchorsMatchLines
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
/// GitHub's log endpoint redirects to S3; `URLSession` follows the redirect automatically
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
///
/// Pipeline order (must not be reordered):
///   1. CR normalisation — converts \r\n and bare \r to \n so every subsequent
///      step receives LF-only input. Must run before any line-aware operation;
///      if skipped, `##[group]\r` would not match `##[group]` in buildLogSections.
///   2. stripAnsi  — character-based; safe on LF-only input.
///   3. stripTimestamps — uses .anchorsMatchLines; requires LF-only input.
///   4. buildLogSections — splits on \n; requires LF-only input.
private func parseStepLog(
    _ raw: String,
    stepNumber: Int,
    logger: (any GitHubLogger)?
) -> String? {
    // Step 1: normalise line endings to LF. \r\n must be replaced before bare \r
    // to avoid doubling blank lines (\r\n → \n\n if the \r pass ran first).
    let normalised = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let ansiStripped = stripAnsi(normalised)    // Step 2
    let cleaned = stripTimestamps(ansiStripped) // Step 3
    let sections = buildLogSections(from: cleaned) // Step 4
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
/// Each section starts at the `##[group]` marker line and runs to (but not including)
/// the next `##[group]` marker. The `##[endgroup]` line is **intentionally included**
/// in the returned section string — it acts as the section terminator and callers
/// use it as a sentinel for display boundaries. It is not stripped here.
///
/// Lines that appear **before the first `##[group]` marker** are silently dropped.
/// For GitHub Actions logs this is by design: preamble lines before the first group
/// are runner boilerplate that the caller does not need. If the log has no `##[group]`
/// markers at all, `buildLogSections` returns `[]` and `parseStepLog` falls back to
/// returning the full cleaned log, making the preamble visible in that case.
///
/// **`hasPrefix` invariant**: By the time this function is called, the full pipeline
/// (CR normalisation → stripAnsi → stripTimestamps) has already run. Every genuine
/// `##[group]` marker emitted by the Actions runner is therefore at the start of its
/// line — the timestamp prefix that preceded it has been removed. `hasPrefix` is used
/// rather than `contains` to avoid false splits on user-emitted log lines that happen
/// to contain the string `##[group]` mid-line (e.g. `echo "##[group]something"` in a
/// `run:` step), which would otherwise silently corrupt section boundaries and shift
/// every subsequent `stepNumber` index by one.
private func buildLogSections(from cleaned: String) -> [String] {
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [String] = []
    var current: [String] = []
    var seenGroup = false
    for line in lines {
        if line.hasPrefix("##[group]") {
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
///
/// Must be called **after** CR normalisation and **before** `stripTimestamps`.
/// See the pipeline-order comment on `parseStepLog` for the full rationale.
private func stripAnsi(_ input: String) -> String {
    guard let ansiRegex else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return ansiRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}

/// Removes the leading GitHub Actions timestamp prefix from every line of `input`.
/// Expects LF-only input — CR normalisation is the caller's responsibility and must
/// have been applied before this function is called (see `parseStepLog`).
/// e.g. `2026-07-29T03:11:15.4722230Z ` is stripped, leaving only the log content.
/// Blank timestamped lines are also matched via the `[^\S\n]*` trailer.
/// Returns `input` unchanged if `timestampRegex` failed to compile at module load time.
private func stripTimestamps(_ input: String) -> String {
    guard let timestampRegex else { return input }
    let range = NSRange(input.startIndex..., in: input)
    return timestampRegex.stringByReplacingMatches(in: input, range: range, withTemplate: "")
}
