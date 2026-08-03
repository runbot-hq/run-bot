// GitHubHelpersTests.swift
// RunBotCoreTests
//
// Tests for the cleanLogText pipeline in GitHubHelpers.swift, plus a focused
// subset of parseStepLog fallback-path tests.
//
// ## What was deleted and why (PR #2370)
// All parseStepLog / buildParsedLog tests that used the synthetic makeLog()
// helper were deleted (makeLog itself is retained — see below). parseStepLog
// is now fallback-only after #2362:
// the primary code path fetches per-step files from the run ZIP and never
// calls parseStepLog. Tests for its ##[group] parsing logic no longer reflect
// the primary production path.
//
// ## Why a minimal subset is kept here
// LogFetcher.fetchStepLog still calls parseStepLog on the flatBlobFallback path
// (when the downloaded ZIP contains no per-step files). A full regression of
// name matching or epilogue routing on that path would go undetected without at
// least a smoke-level test. The three tests below cover the reachable contracts:
//   - exact name match (stage 1)
//   - "Run "-prefix normalisation (stage 2)
//   - synthetic-step epilogue heuristic — Complete job (stage 3)
//
// ## cleanLogText coverage map
//   timestamp stripping                     — test_timestampStripping
//   ANSI stripping                          — test_ansiStripping
//   ANSI + timestamp compose (ANSI-after-Z) — test_ansiAndTimestampCompose
//   CRLF normalisation                      — test_crlfNormalisation
//   bare CR normalisation                   — test_bareCrNormalisation
import Foundation
@testable import GitHubClient
import XCTest

/// Tests for `cleanLogText` (ZIP-path cleaning pipeline) and a minimal smoke
/// suite for the `parseStepLog` flat-blob fallback path in `LogFetcher.fetchStepLog`.
final class GitHubHelpersTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal raw log string with the given named sections.
    /// Timestamps are omitted intentionally — this helper targets parser
    /// structure, not the cleaning pipeline.
    private func makeLog(
        preamble: [String] = [],
        sections: [(name: String, body: [String])] = [],
        epilogue: [String] = []
    ) -> String {
        var lines: [String] = []
        lines += preamble
        for s in sections {
            lines.append("##[group]\(s.name)")
            lines += s.body
            lines.append("##[endgroup]")
        }
        lines += epilogue
        return lines.joined(separator: "\n")
    }

    // MARK: - parseStepLog fallback-path coverage
    // These three tests guard the flatBlobFallback path in LogFetcher.fetchStepLog.
    // parseStepLog is public so RunBotCore can invoke it when the ZIP lacks per-step files.

    /// Verifies stage-1 exact name matching: the step name must match the
    /// `##[group]` header directly, returning only the matched section.
    func test_fallback_exactNameMatch() {
        let raw = makeLog(sections: [
            (name: "Build", body: ["build output"]),
            (name: "Test",  body: ["test output"])
        ])
        let result = parseStepLog(raw, stepName: "Build", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result, "Stage-1 exact match must find the section")
        XCTAssert(result!.contains("build output"))
        XCTAssertFalse(result!.contains("test output"),
            "Only the matched section must be returned")
    }

    /// Verifies stage-2 `Run`-prefix normalisation: a step name without the
    /// `Run ` prefix must match a `##[group]` header that has it, and vice versa.
    func test_fallback_runPrefixNormalisation() {
        let raw = makeLog(sections: [
            (name: "Run actions/checkout@v4", body: ["Fetching the repository"]),
            (name: "Run build",               body: ["unrelated build output"])
        ])
        let result = parseStepLog(raw, stepName: "actions/checkout@v4", stepNumber: 2, logger: nil)
        XCTAssertNotNil(result, "Run-prefix normalisation must bridge step name to ##[group] header")
        XCTAssert(result!.contains("Fetching the repository"))
        XCTAssertFalse(result!.contains("unrelated build output"),
            "Run-prefix match must return only the matched section")
    }

    /// Verifies stage-3 synthetic-step epilogue heuristic: `Complete job` (which
    /// produces no `##[group]` markers in real logs) must be routed to the
    /// epilogue section, not return nil or the full log blob.
    func test_fallback_completeJobEpilogueHeuristic() {
        let raw = makeLog(
            sections: [(name: "Run some-action", body: ["doing work"])],
            epilogue: ["Post job cleanup.", "Cleaning up orphan processes"]
        )
        let result = parseStepLog(raw, stepName: "Complete job", stepNumber: 99, logger: nil)
        XCTAssertNotNil(result, "Complete job must resolve to the epilogue section")
        XCTAssert(result!.contains("Post job cleanup."),
            "Epilogue content must be returned for the synthetic Complete job step")
        XCTAssertFalse(result!.contains("doing work"),
            "Body of an unrelated section must not bleed into the epilogue result")
    }

    /// Verifies that stage-1 matching is case-insensitive: a step name that
    /// differs only in casing from the `##[group]` header must still match.
    /// This path was a real prior regression — case-sensitive matching caused
    /// steps like "Set up job" (API) vs "set up job" (log header) to miss.
    func test_fallback_exactNameMatch_caseInsensitive() {
        let raw = makeLog(sections: [
            (name: "Set Up Job", body: ["runner provisioned"]),
            (name: "Build",      body: ["build output"])
        ])
        let result = parseStepLog(raw, stepName: "set up job", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result, "Case-insensitive match must find the section")
        XCTAssert(result!.contains("runner provisioned"))
        XCTAssertFalse(result!.contains("build output"),
            "Only the matched section must be returned")
    }

    /// Verifies that lines between `##[group]` blocks are not duplicated in the
    /// matched section. A prior regression caused inter-group orphan lines to
    /// be appended to the *next* matched section, inflating its output.
    func test_fallback_interGroupLines_noDuplication() {
        // Raw log: orphan line lives between two groups.
        let orphanLine = "2026-01-01T00:00:00Z orphan line between groups"
        let raw = [
            "2026-01-01T00:00:00Z ##[group]Build",
            "2026-01-01T00:00:00Z build line",
            "2026-01-01T00:00:00Z ##[endgroup]",
            orphanLine,
            "2026-01-01T00:00:00Z ##[group]Test",
            "2026-01-01T00:00:00Z test line",
            "2026-01-01T00:00:00Z ##[endgroup]"
        ].joined(separator: "\n")
        let result = parseStepLog(raw, stepName: "Test", stepNumber: 2, logger: nil)
        XCTAssertNotNil(result, "Test section must be found")
        XCTAssertFalse(result!.contains("orphan line between groups"),
            "Inter-group orphan lines must not bleed into the following section")
        XCTAssert(result!.contains("test line"))
    }

    /// Verifies that buildParsedLog ignores a stray `##[endgroup]` before the first
    /// `##[group]` header rather than emitting an empty synthetic section or crashing.
    func test_buildParsedLog_orphanEndgroup_isIgnored() {
        let raw = [
            "preamble",
            "##[endgroup]",
            "##[group]Build",
            "build line",
            "##[endgroup]"
        ].joined(separator: "\n")
        let parsed = buildParsedLog(from: raw)
        // Orphan ##[endgroup] must not generate a section; only the real Build section exists.
        XCTAssertEqual(parsed.sections.count, 1,
            "A stray endgroup before the first group must be ignored")
        XCTAssertEqual(parsed.sections.first?.name, "Build")
        // body includes the ##[group] header line + body lines + ##[endgroup] marker.
        XCTAssert(parsed.sections.first?.body.contains("build line") == true,
            "Build section body must contain the body line")
        XCTAssertFalse(parsed.sections.first?.body.contains("preamble") == true,
            "Preamble must not bleed into the Build section body")
        XCTAssertEqual(parsed.epilogue, "",
            "No epilogue should be synthesised from an orphan endgroup")
    }

    /// Verifies that back-to-back `##[group]` headers flush the previous open section
    /// before starting the next one, even if the first header forgot its `##[endgroup]`.
    func test_buildParsedLog_backToBackGroups_flushPreviousSection() {
        let raw = [
            "##[group]Build",
            "build line",
            "##[group]Test",
            "test line",
            "##[endgroup]"
        ].joined(separator: "\n")
        let parsed = buildParsedLog(from: raw)
        // A second ##[group] must flush the first section with a synthetic ##[endgroup].
        XCTAssertEqual(parsed.sections.count, 2,
            "A second group header must flush the previous open section")
        XCTAssertEqual(parsed.sections[0].name, "Build")
        XCTAssert(parsed.sections[0].body.contains("build line"),
            "Build section body must contain its body line")
        XCTAssertFalse(parsed.sections[0].body.contains("test line"),
            "Test section body must not bleed into Build section")
        XCTAssertEqual(parsed.sections[1].name, "Test")
        XCTAssert(parsed.sections[1].body.contains("test line"),
            "Test section body must contain its body line")
    }

    /// Verifies that ANSI SGR sequences are **preserved** by `parseStepLog`.
    ///
    /// Since #2413, ANSI is no longer stripped at parse time — it passes through
    /// to the UI layer for rendering by `ansiAttributedString`.
    func test_parseStepLog_ansiPassThrough() {
        let esc = "\u{001B}"
        let raw = makeLog(sections: [
            (name: "Build", body: ["\(esc)[32mbuild output\(esc)[0m"])
        ])
        let result = parseStepLog(raw, stepName: "Build", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains(esc),
            "parseStepLog must preserve ANSI sequences — stripping happens at the render layer")
        XCTAssert(result!.contains("build output"))
    }

    // MARK: - cleanLogText pipeline

    /// Verifies that ISO-8601 timestamp prefixes (`2026-…Z`) are stripped,
    /// leaving only the log content on each line.
    func test_timestampStripping() {
        let raw = "2026-07-29T03:11:15.4722230Z output line\n2026-07-29T03:11:16.0000000Z second line"
        let result = cleanLogText(raw)
        XCTAssertFalse(result.contains("2026-"), "Timestamp prefix must be stripped")
        XCTAssert(result.contains("output line"))
        XCTAssert(result.contains("second line"))
    }

    /// Verifies that ANSI SGR escape sequences are **preserved** by `cleanLogText`.
    ///
    /// Since #2413, ANSI sequences are no longer stripped in the cleaning pipeline —
    /// they pass through untouched and are rendered by `ansiAttributedString` in the
    /// UI layer (`LogPlainLine`, `LogDimmedLine`).
    func test_ansiPassThrough() {
        let esc = "\u{001B}"
        let raw = "\(esc)[32mGreen text\(esc)[0m\nplain line"
        let result = cleanLogText(raw)
        XCTAssert(result.contains(esc), "ANSI escape sequences must pass through cleanLogText untouched")
        XCTAssert(result.contains("Green text"))
        XCTAssert(result.contains("plain line"))
    }

    /// Verifies the ANSI-after-Z edge case: an ANSI escape sitting between the
    /// timestamp `Z` sentinel and the log content.
    ///
    /// Since #2413, ANSI sequences are preserved by `cleanLogText`. The timestamp
    /// prefix must still be stripped cleanly even when an ANSI escape directly
    /// follows the `Z` sentinel.
    /// Pipeline order: CRLF → stripTimestamps (ANSI passes through).
    func test_ansiAndTimestampCompose() {
        let esc = "\u{001B}"
        let raw = "2026-07-29T03:11:16.0000000Z \(esc)[32mcoloured output\(esc)[0m"
        let result = cleanLogText(raw)
        XCTAssertFalse(result.contains("2026-"),
            "Timestamp prefix must be stripped")
        XCTAssert(result.contains(esc),
            "ANSI escape sequences must pass through cleanLogText untouched")
        XCTAssert(result.contains("coloured output"),
            "Content must survive timestamp stripping")
    }

    /// Verifies that Windows-style CRLF line endings are normalised to LF,
    /// leaving no bare `\r` characters in the output.
    func test_crlfNormalisation() {
        let raw = "line one\r\nline two\r\nline three"
        let result = cleanLogText(raw)
        XCTAssert(result.contains("line one"))
        XCTAssert(result.contains("line two"))
        XCTAssertFalse(result.contains("\r"), "CRLF must be normalised to LF")
    }

    /// Verifies that bare CR (`\r`) line endings (classic Mac style) are
    /// normalised, leaving no `\r` characters in the output.
    func test_bareCrNormalisation() {
        let raw = "line one\rline two\rline three"
        let result = cleanLogText(raw)
        XCTAssert(result.contains("line one"))
        XCTAssert(result.contains("line two"))
        XCTAssertFalse(result.contains("\r"), "Bare CR must be normalised")
    }
}
