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

/// A parsed section of a GitHub Actions log, keyed by the group name from `##[group]<name>`.
///
/// Produced by `buildParsedLog`. The `name` is the exact text that follows the `##[group]`
/// marker (e.g. `"Run actions/checkout@v4"`). The `body` is the cleaned content between
/// the group and endgroup markers, with the marker lines themselves included so callers
/// can render them as section boundaries if needed.
///
/// Read-only by design; construction is intentionally internal to GitHubHelpers.
public struct LogSection {
    /// The name extracted from the `##[group]<name>` marker line.
    public let name: String
    /// Cleaned body lines between (and including) the ##[group] and ##[endgroup] markers.
    /// The marker lines are intentionally retained so the UI can render them as visible
    /// section boundaries in the monospaced log view without a separate stripping pass.
    public let body: String
}

/// Full parse result for a GitHub Actions log: named sections plus ungrouped regions.
///
/// - `sections`: In-order named sections delimited by `##[group]`/`##[endgroup]` pairs.
/// - `preamble`: Lines before the first `##[group]` marker (e.g. "Set up job" runner output).
/// - `epilogue`: Lines after the last `##[endgroup]` marker, including any inter-group lines
///   that appeared between consecutive `##[endgroup]`/`##[group]` pairs during the run.
private struct ParsedLog {
    let sections: [LogSection]
    let preamble: String
    let epilogue: String
}

/// Fetches the log for a single step via the transport layer's `raw()` method.
@concurrent
public func fetchStepLog(
    jobID: Int,
    stepNumber: Int,
    stepName: String,
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
    transport.logger?.log("fetchStepLog › fetching \(endpoint) step=\(stepNumber) name=\(stepName)", category: "transport")
    guard let raw = await fetchAndDecodeStepLog(endpoint: endpoint, jobID: jobID, transport: transport) else {
        return nil
    }
    return parseStepLog(raw, stepName: stepName, stepNumber: stepNumber, logger: transport.logger)
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

/// Extracts the log section for `stepName` from a raw multi-group log string.
///
/// Matching strategy (in order):
///   1. Exact match on `step.name` against `##[group]<name>`.
///   2. Case-insensitive prefix match — handles the common case where the `##[group]`
///      header is `"Run actions/checkout@v4"` but `step.name` is `"actions/checkout@v4"`
///      (GitHub prepends `"Run "` to `run:` step names in the log but not in the API).
///      Only the forward direction is matched (section name has step name as prefix)
///      to avoid false positives from short step names matching unrelated sections.
///   3. Synthetic step heuristics:
///      - "Set up job" / "Initialize containers" → preamble (lines before first group)
///      - Names starting with "Post " / "Complete job" / "Stop containers" → epilogue
///        Returning nil (not the full-log fallback) when preamble/epilogue is empty is
///        deliberate: it shows "Log not available" rather than dumping thousands of
///        unrelated lines when the synthetic step produced no output of its own.
///   4. Fallback: return the full cleaned log.
///
/// This replaces the old integer-index approach. `step.number` from the GitHub API counts
/// all steps including synthetic ones ("Set up job", "Complete job", "Post Run X") that
/// have no `##[group]` block in the raw log, so `stepNumber - 1` was always misaligned.
///
/// Pipeline order (must not be reordered):
///   1. CR normalisation — converts \r\n and bare \r to \n.
///   2. stripAnsi  — character-based; safe on LF-only input.
///   3. stripTimestamps — uses .anchorsMatchLines; requires LF-only input.
///   4. buildParsedLog — splits on \n; requires LF-only input.
private func parseStepLog(
    _ raw: String,
    stepName: String,
    stepNumber: Int,
    logger: (any GitHubLogger)?
) -> String? {
    // Step 1: normalise line endings to LF.
    let normalised = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let ansiStripped = stripAnsi(normalised)    // Step 2
    let cleaned = stripTimestamps(ansiStripped) // Step 3
    let parsed = buildParsedLog(from: cleaned)  // Step 4

    logger?.log(
        "parseStepLog › \(parsed.sections.count) section(s), stepName=\"\(stepName)\" stepNumber=\(stepNumber)",
        category: "transport")

    // 1. Exact name match
    if let match = parsed.sections.first(where: { $0.name == stepName }) {
        logger?.log("parseStepLog › exact match \"\(stepName)\"", category: "transport")
        return match.body
    }

    // 2. Case-insensitive prefix match — section name starts with step name.
    //    e.g. step.name="actions/checkout@v4", group header="Run actions/checkout@v4".
    //    Only the forward direction (section.hasPrefix(stepName)) is checked; the reverse
    //    would allow a short step name like "Run" or "Post" to match any section, bypassing
    //    the synthetic heuristics in step 3.
    let lower = stepName.lowercased()
    if let match = parsed.sections.first(where: { $0.name.lowercased().hasPrefix(lower) }) {
        logger?.log("parseStepLog › prefix match \"\(match.name)\" for \"\(stepName)\"", category: "transport")
        return match.body
    }

    // 3. Synthetic step heuristics
    let lowerName = stepName.lowercased()
    if lowerName == "set up job" || lowerName == "initialize containers" {
        logger?.log("parseStepLog › synthetic preamble for \"\(stepName)\"", category: "transport")
        // Returning nil (not fallback) when empty is deliberate — see doc comment above.
        return parsed.preamble.isEmpty ? nil : parsed.preamble
    }
    if lowerName.hasPrefix("post ") || lowerName == "complete job" || lowerName == "stop containers" {
        logger?.log("parseStepLog › synthetic epilogue for \"\(stepName)\"", category: "transport")
        // Returning nil (not fallback) when empty is deliberate — see doc comment above.
        return parsed.epilogue.isEmpty ? nil : parsed.epilogue
    }

    // 4. Fallback: return full cleaned log
    logger?.log(
        "parseStepLog › no match for \"\(stepName)\", returning full log",
        category: "transport")
    return cleaned
}

/// Splits a cleaned log into a `ParsedLog` with named sections, a preamble, and an epilogue.
///
/// - Preamble: all lines before the first `##[group]` marker.
/// - Sections: lines between a `##[group]<name>` and `##[endgroup]` (both markers included
///   in `body`), in source order.
/// - Epilogue: all lines after the last `##[endgroup]` marker. This includes any inter-group
///   lines that appeared between an `##[endgroup]` and the next `##[group]` during the run
///   (e.g. blank separator lines or runner annotations). Such lines are accumulated in
///   `interGroupLines` during the loop and prepended to the final post-loop tail so that
///   none are silently dropped.
///
/// Malformed logs (a `##[group]` with no matching `##[endgroup]`) are handled gracefully:
/// the open section is flushed at end-of-input rather than silently dropped.
///
/// `hasPrefix("##[group]")` is used (not `contains`) to avoid false splits on user-emitted
/// `echo "##[group]something"` lines — the upstream pipeline has already stripped the
/// timestamp prefix so genuine markers are always at column 0.
private func buildParsedLog(from cleaned: String) -> ParsedLog {
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [LogSection] = []
    var preambleLines: [String] = []
    var currentName: String?
    var currentBody: [String] = []
    var seenFirstGroup = false
    var lastEndgroupIdx: Int?
    // Accumulates lines that fall between an ##[endgroup] and the next ##[group].
    // These are folded into the epilogue at the end so they are never silently dropped.
    var interGroupLines: [String] = []

    for (idx, line) in lines.enumerated() {
        if line.hasPrefix("##[group]") {
            // Flush previous open section (handles back-to-back groups without endgroup)
            if let name = currentName, !currentBody.isEmpty {
                sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
            }
            // Any inter-group lines collected since the last ##[endgroup] are kept in
            // interGroupLines and will be prepended to the epilogue after the loop.
            seenFirstGroup = true
            currentName = String(line.dropFirst("##[group]".count))
            currentBody = [line]
        } else if line.hasPrefix("##[endgroup]") {
            currentBody.append(line)
            if let name = currentName {
                sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
            }
            currentName = nil
            currentBody = []
            lastEndgroupIdx = idx
        } else if currentName != nil {
            currentBody.append(line)
        } else if !seenFirstGroup {
            preambleLines.append(line)
        } else {
            // seenFirstGroup == true && currentName == nil: between ##[endgroup] and next
            // ##[group] (or end of file). Accumulate so they reach the epilogue.
            interGroupLines.append(line)
        }
    }

    // Flush any open section that had no ##[endgroup] (malformed but handle gracefully)
    if let name = currentName, !currentBody.isEmpty {
        sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
    }

    // Epilogue: inter-group lines accumulated above, followed by every line after the
    // last ##[endgroup]. The two regions are concatenated so that lines between any
    // ##[endgroup]/##[group] pair are preserved alongside the true post-run tail.
    var epilogueLines: [String] = interGroupLines
    if let endIdx = lastEndgroupIdx, endIdx + 1 < lines.count {
        epilogueLines += Array(lines[(endIdx + 1)...])
    }

    return ParsedLog(
        sections: sections,
        preamble: preambleLines.joined(separator: "\n"),
        epilogue: epilogueLines.joined(separator: "\n")
    )
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
