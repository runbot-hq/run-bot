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
/// Note: `stripAnsi` is no longer called by any active fetch path — ANSI sequences are
/// preserved and rendered by `ansiAttributedString` at the UI layer. This regex and
/// `stripAnsi` are retained for any future use or testing contexts that may need
/// unconditional stripping.
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
/// **Fractional seconds (`\.\\d+`)?** — The group is optional (`?`) to cover whole-second
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

// MARK: - Internal log-parsing types (used by parseStepLog / buildParsedLog for flat-blob fallback)

/// A named section of a GitHub Actions log delimited by `##[group]`/`##[endgroup]` markers.
/// Internal only — not part of the public API. Used by `buildParsedLog` and `parseStepLog`
/// for the flat-blob fallback path in `LogFetcher.fetchStepLog`.
struct LogSection {
    /// The `##[group]` header text for this section.
    let name: String
    /// The log lines between `##[group]` and `##[endgroup]`.
    let body: String
}

/// Full parse result from `buildParsedLog`: named sections, preamble, and epilogue.
/// Internal only — not part of the public API.
struct ParsedLog {
    /// All named `##[group]` sections found in the log.
    let sections: [LogSection]
    /// Log lines that appear before the first `##[group]` marker.
    let preamble: String
    /// Log lines that appear after the last `##[endgroup]` marker.
    let epilogue: String
}

/// Extracts the log section for `stepName` from a raw multi-group log string.
///
/// **Visibility**: internal (no explicit modifier) so the test target can call it directly
/// via `@testable import GitHubClient`. This is intentional and correct — do not
/// change to private. It is not part of the public API.
///
/// Matching strategy (in order):
///   1. Case-insensitive exact match on `stepName` against `##[group]<name>`. Using
///      lowercased() on both sides ensures a step named "POST DEPLOY" matches a section
///      header "Post deploy" and vice-versa, without risking a prefix over-match.
///   2. "Run "-prefix normalisation — GitHub prepends `"Run "` to `run:` step names in the
///      log group header but not in the API step name. A section named `"Run actions/checkout@v4"`
///      therefore matches a step named `"actions/checkout@v4"`. The comparison is
///      case-insensitive and checks only the exact two forms (with and without `"Run "`)
///      to avoid general prefix over-matching (e.g. "Build" must not match
///      "Build documentation").
///      **This normalisation is intentionally one-directional and the design is complete**:
///      it handles the only case that arises in practice — a step whose API name has no
///      "Run " prefix but whose log group header does. The inverse direction (step named
///      "Run X", section header "X" without the "Run " prefix) does not arise because
///      GitHub Actions always adds "Run " in the log group header and never in the API
///      step name. Handling the inverse would require a second, asymmetric check that
///      serves no real case and would risk false matches.
///      **Stage-2 is only reached when stage 1 has already failed**, meaning no section
///      is named exactly `stepName` (case-insensitively). Therefore, if `stepName` itself
///      starts with `"run "` (e.g. `"run build"`), stage 1 has already checked for a section
///      named `"run build"` and found none. Stage 2 then constructs `"run run build"` as
///      the candidate, which will not match any real section and falls through to stage 3.
///      This edge is harmless: it produces no false match, only an extra no-op lookup.
///      **Ordering guarantee**: steps 1–2 match against *section names* and run before
///      step 3, which matches against the *step name*. A user step named "Post deploy"
///      whose log emits `##[group]Run Post deploy` is therefore caught by step 2
///      (lowerSection == "run post deploy" == "run " + lowerStep) and never reaches the
///      synthetic heuristic in step 3. A user step named "Post Run X" whose log emits
///      `##[group]Run Post Run X` is likewise caught by step 2 and never reaches step 3.
///   3. Synthetic step heuristics (applied to `stepName`, not section names):
///      - "Set up job" / "Initialize containers" → preamble (lines before first group)
///      - Names starting with "Post " / "Complete job" / "Stop containers" → epilogue
///        Returning nil (not the full-log fallback) when preamble/epilogue is empty is
///        deliberate: it shows "Log not available" rather than dumping thousands of
///        unrelated lines when the synthetic step produced no output of its own.
///        These prefixes and names match only GitHub's own synthetic steps; any real step
///        with a matching name would have been caught by steps 1–2 first.
///   4. Fallback: return the full cleaned log.
///
/// This replaces the old integer-index approach. `step.number` from the GitHub API counts
/// all steps including synthetic ones ("Set up job", "Complete job", "Post Run X") that
/// have no `##[group]` block in the raw log, so `stepNumber - 1` was always misaligned.
///
/// Pipeline order (must not be reordered):
///   1. CR normalisation — converts \r\n and bare \r to \n.
///   2. stripTimestamps — uses .anchorsMatchLines; requires LF-only input.
///   3. buildParsedLog — splits on \n; requires LF-only input.
///
/// ANSI escape sequences are **preserved** and passed through to the UI layer
/// (`ansiAttributedString` in `LogPlainLine` / `LogDimmedLine`), consistent
/// with the `cleanLogText` pipeline. `stripAnsi` is intentionally not called.
/// - Note: Visibility is `public` so `LogFetcher` (in `RunBotCore`) can call it
///   for the flat-blob fallback path without duplicating the matching logic.
public func parseStepLog(
    _ raw: String,
    stepName: String,
    stepNumber: Int,
    logger: (any GitHubLogger)?
) -> String? {
    // Step 1: normalise line endings to LF.
    let normalised = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    let cleaned = stripTimestamps(normalised) // Step 2 (ANSI passes through)
    let parsed = buildParsedLog(from: cleaned) // Step 3

    logger?.log(
        "parseStepLog › \(parsed.sections.count) section(s), stepName=\"\(stepName)\" stepNumber=\(stepNumber)",
        category: "transport")

    // lowerStep is shared by stages 1, 2, and 3.
    let lowerStep = stepName.lowercased()

    // 1. Case-insensitive exact name match.
    if let match = parsed.sections.first(where: { $0.name.lowercased() == lowerStep }) {
        logger?.log("parseStepLog › exact match \"\(stepName)\"", category: "transport")
        return match.body
    }

    // 2. "Run "-prefix normalisation.
    //    GitHub's log group headers prepend "Run " to run: step names, but the API step
    //    name does not include this prefix. Check the "Run "-prefixed form with a
    //    case-insensitive exact comparison. General hasPrefix is intentionally avoided:
    //    "Build" must not match "Build documentation".
    //    This normalisation is intentionally one-directional and the design is complete —
    //    see the doc comment above for the full rationale.
    //
    //    Edge case — stepName already starts with "run " (e.g. "run build"):
    //    Stage 1 already performed an exact case-insensitive check for a section named
    //    "run build" and found none (otherwise we would have returned above). Stage 2
    //    therefore constructs "run run build" as the candidate, which will not match any
    //    real GitHub Actions section header and falls through to stage 3 harmlessly.
    //    No false match is possible; it is simply one extra no-op lookup.
    if let match = parsed.sections.first(where: {
        $0.name.lowercased() == "run \(lowerStep)"
    }) {
        logger?.log("parseStepLog › run-prefix match \"\(match.name)\" for \"\(stepName)\"", category: "transport")
        return match.body
    }

    // 3. Synthetic step heuristics
    if lowerStep == "set up job" || lowerStep == "initialize containers" {
        logger?.log("parseStepLog › synthetic preamble for \"\(stepName)\"", category: "transport")
        // Returning nil (not fallback) when empty is deliberate — see doc comment above.
        // Use .whitespacesAndNewlines so a preamble consisting only of blank/space-padded
        // lines doesn't reach the UI as a non-empty but visually blank log.
        let trimmed = parsed.preamble.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if lowerStep.hasPrefix("post ") || lowerStep == "complete job" || lowerStep == "stop containers" {
        logger?.log("parseStepLog › synthetic epilogue for \"\(stepName)\"", category: "transport")
        // Returning nil (not fallback) when empty is deliberate — see doc comment above.
        // Use .whitespacesAndNewlines so an epilogue consisting only of blank/space-padded
        // lines doesn't reach the UI as a non-empty but visually blank log.
        let trimmed = parsed.epilogue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // 4. Fallback: return full cleaned log
    logger?.log(
        "parseStepLog › no match for \"\(stepName)\", returning full log",
        category: "transport")
    return cleaned
}

/// Splits a cleaned log into a `ParsedLog` with named sections, a preamble, and an epilogue.
///
/// **Visibility**: internal (no explicit modifier) so the test target can call it directly
/// via `@testable import GitHubClient`. It is not part of the public API.
///
/// - Preamble: all lines before the first `##[group]` marker.
/// - Sections: lines between a `##[group]<name>` and `##[endgroup]` (both markers included
///   in `body`), in source order.
/// - Epilogue: all out-of-section lines after the first group: both lines between consecutive
///   `##[endgroup]`/`##[group]` pairs and lines after the final `##[endgroup]`. All such lines
///   are accumulated into `interGroupLines` during the loop; no separate post-loop slice is
///   needed, so there is no risk of double-counting the final tail.
///
/// Malformed logs (a `##[group]` with no matching `##[endgroup]`) are handled gracefully:
/// the open section is flushed at end-of-input rather than silently dropped.
///
/// Back-to-back `##[group]` markers (second group arrives while the first is still open):
/// the open section is flushed immediately. A synthetic `##[endgroup]` line is appended to
/// the body before flushing so that `LogSection.body` always contains both the opening and
/// closing markers, honouring the documented body contract regardless of how the section
/// was closed.
///
/// A `##[endgroup]` with no matching open `##[group]` (orphan endgroup) is silently discarded:
/// it is not added to preamble, epilogue, or any section. This is intentional — orphan markers
/// are a runner artefact and carry no log content.
///
/// `hasPrefix("##[group]")` is used (not `contains`) to avoid false splits on user-emitted
/// `echo "##[group]something"` lines — the upstream pipeline has already stripped the
/// timestamp prefix so genuine markers are always at column 0.
func buildParsedLog(from cleaned: String) -> ParsedLog {
    let lines = cleaned.components(separatedBy: "\n")
    var sections: [LogSection] = []
    var preambleLines: [String] = []
    var currentName: String?
    var currentBody: [String] = []
    var seenFirstGroup = false
    // Accumulates every out-of-section line after the first ##[group]: both inter-group
    // lines (between ##[endgroup] and the next ##[group]) and the post-final-endgroup tail.
    // Using a single buffer avoids the double-counting that occurs when a post-loop slice
    // is concatenated with an inter-group buffer.
    var interGroupLines: [String] = []

    for line in lines {
        if line.hasPrefix("##[group]") {
            // Flush previous open section (handles back-to-back groups without endgroup).
            // A synthetic ##[endgroup] is appended before flushing so that LogSection.body
            // always contains both markers, honouring the documented body contract.
            if let name = currentName {
                currentBody.append("##[endgroup]")
                sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
            }
            seenFirstGroup = true
            currentName = String(line.dropFirst("##[group]".count))
            currentBody = [line]
        } else if line.hasPrefix("##[endgroup]") {
            if let name = currentName {
                // Normal close: append the endgroup marker to the section body, flush the section.
                currentBody.append(line)
                sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
                currentName = nil
                currentBody = []
            }
            // Orphan ##[endgroup] (currentName == nil): intentionally discarded — not added
            // to preamble, interGroupLines, or any section. See buildParsedLog doc comment.
        } else if currentName != nil {
            currentBody.append(line)
        } else if !seenFirstGroup {
            preambleLines.append(line)
        } else {
            // seenFirstGroup == true && currentName == nil: between ##[endgroup] and the
            // next ##[group], or after the final ##[endgroup]. Both cases land here.
            interGroupLines.append(line)
        }
    }

    // Flush any open section that had no ##[endgroup] (malformed but handle gracefully).
    // No synthetic ##[endgroup] is appended here: the end-of-input flush is for truly
    // unclosed groups (the log was truncated), and callers inspecting body for a trailing
    // marker should treat absence of ##[endgroup] as a signal that the log was cut short.
    if let name = currentName {
        sections.append(LogSection(name: name, body: currentBody.joined(separator: "\n")))
    }

    return ParsedLog(
        sections: sections,
        preamble: preambleLines.joined(separator: "\n"),
        epilogue: interGroupLines.joined(separator: "\n")
    )
}

// MARK: - Public cleaning helper (for use in RunBotCore's LogFetcher ZIP path)

/// Applies the standard CR → timestamp-strip pipeline to `raw` and returns
/// the cleaned text. Exposed as `public` so `LogFetcher.fetchStepLog` (in `RunBotCore`)
/// can clean ZIP slice content without duplicating the regex logic.
///
/// ANSI escape sequences are intentionally **preserved** — they are rendered by
/// `ansiAttributedString` in the UI layer (`LogPlainLine`, `LogDimmedLine`).
/// This is consistent with the `parseStepLog` pipeline; `stripAnsi` is not called
/// on any active fetch path.
///
/// Pipeline:
///   1. CR normalisation (`\r\n` and bare `\r` → `\n`)
///   2. Timestamp prefix removal
public func cleanLogText(_ raw: String) -> String {
    let normalised = raw
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    return stripTimestamps(normalised)
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
