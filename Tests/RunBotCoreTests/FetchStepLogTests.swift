// FetchStepLogTests.swift
// RunBotCoreTests
//
// Tests for LogFetcher.fetchStepLog and sanitizeJobNameForZIP (issue #2362).
//
// ## Design note
// `fetchStepLog` calls `zipExtractor` (a stored @Sendable closure) to convert
// raw ZIP bytes into [(name, text)] tuples. The live default spawns /usr/bin/unzip
// via ProcessRunner, which the test-sandbox blocks. Tests inject a closure that
// returns pre-built tuples directly — no subprocess, no filesystem.
//
// The exception is `test_completeJob_regression2358_realExtractor`, which uses
// the real ZipExtractor against the shared fixture ZIP from TestFixtures.swift.
// This is the only test that exercises the actual unzip → cleanLogText pipeline
// end-to-end.
//
// Coverage map:
//   Normal step — ANSI + timestamp stripped                  — test_normalStep_returnsSlice
//   Regression #2358 — synthetic "Complete job" step (stub)  — test_completeJob_regression2358
//   Regression #2358 — real extractor against fixture ZIP    — test_completeJob_regression2358_realExtractor
//   Prefix match when filename differs from step.name        — test_sanitisedFilenameDiffers_prefixMatchSucceeds
//   Whitespace-only content → .syntheticEmpty                — test_emptyContent_returnsSyntheticEmpty
//   Only top-level blobs (no '/') → .flatBlobFallback        — test_onlyTopLevelBlobs_returnsFlatBlobFallback
//   Job name with / and : — sanitisation applied             — test_jobNameWithSlashAndColon_sanitised
//   Job name > 90 UTF-16 units — truncation applied          — test_jobNameExceeds90UTF16Units_truncated
//   Cache hit — second call makes 0 additional network calls — test_cacheHit_zeroAdditionalNetworkCalls
//
//   sanitizeJobNameForZIP: strips slash                      — test_sanitize_stripsSlash
//   sanitizeJobNameForZIP: strips colon                      — test_sanitize_stripsColon
//   sanitizeJobNameForZIP: truncates at 90 UTF-16 units      — test_sanitize_truncatesAt90UTF16
//   sanitizeJobNameForZIP: preserves short ASCII name        — test_sanitize_preservesShortName

import Foundation
import Testing
import GitHubClient
@testable import RunBotCore

// MARK: - Shared helpers

/// Builds a `GitHubStep` via the public `Decodable` path.
private func makeStep(number: Int, name: String) -> GitHubStep {
    let json = """
    {"name":"\(name)","status":"completed","conclusion":"success","number":\(number)}
    """
    return try! JSONDecoder().decode(GitHubStep.self, from: Data(json.utf8))
}

/// Builds a `LogFetcher` with a stub transport and a no-subprocess extractor.
///
/// - `zipFiles`: The entries the extractor returns directly (bypasses unzip).
/// - `rawResponses`: URL-prefix → Data map forwarded to `StubTransport`.
///   A default ZIP-endpoint entry (`repos/owner/repo/actions/runs/99/logs`) is
///   always included so the transport guard never trips. The content is irrelevant
///   because the injected `zipExtractor` ignores the raw bytes entirely.
private func makeFetcher(
    zipFiles: [(name: String, text: String)],
    extraResponses: [String: Data] = [:]
) -> LogFetcher {
    var responses: [String: Data] = [
        "repos/owner/repo/actions/runs/99/logs": Data("ZIP".utf8),
        "repos/owner/repo/actions/jobs/42/logs": Data("flat blob content\n".utf8),
    ]
    for (k, v) in extraResponses { responses[k] = v }
    let transport = StubTransport(responses: responses)
    return LogFetcher(
        transport: transport,
        zipExtractor: { _ in .success(zipFiles) }
    )
}

// MARK: - LogFetcher.fetchStepLog tests

@Suite("LogFetcher.fetchStepLog")
struct FetchStepLogTests {

    @Test("Normal step: returns .slice with ANSI and timestamps stripped")
    func test_normalStep_returnsSlice() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/2_Checkout", text: "2026-01-01T00:00:01.000Z \u{1B}[32msome output\u{1B}[0m\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 2, name: "Checkout"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice, got \(result)")
            return
        }
        #expect(content.contains("some output"), "Content must be present")
        #expect(!content.contains("2026-"), "Timestamps must be stripped")
        #expect(!content.contains("\u{1B}"), "ANSI codes must be stripped")
    }

    @Test("Regression #2358: synthetic Complete job step returns .slice, not .syntheticEmpty")
    func test_completeJob_regression2358() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/7_Complete job", text: "Cleaning up orphan processes\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 7, name: "Complete job"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("REGRESSION #2358: Expected .slice for synthetic step, got \(result)")
            return
        }
        #expect(content.contains("Cleaning up orphan processes"))
    }

    /// THE #2358 REGRESSION TEST — real unzip subprocess, real fixture ZIP.
    ///
    /// Unlike `test_completeJob_regression2358` (stub extractor), this test runs
    /// the actual /usr/bin/unzip subprocess against the committed fixture in
    /// TestFixtures.swift. It exercises the full pipeline:
    ///   transport → raw ZIP bytes → unzip subprocess → file enumeration
    ///   → cleanLogText (strip timestamps + ANSI) → StepLogResult.slice
    ///
    /// If this test fails while the stub test passes, the regression is in
    /// the extraction layer (unzipLogs / file enumeration), not in routing logic.
    @Test("Regression #2358: Complete job with no ##[group] markers — real extractor returns .slice")
    func test_completeJob_regression2358_realExtractor() async {
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs/99/logs": fixtureZip,
        ])
        var fetcher = LogFetcher(transport: transport) // real zipExtractor
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-07-31T04:34:20Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 7, name: "Complete job"),
            scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record(
                """
                REGRESSION #2358 (real extractor): Expected .slice for 'Complete job', got \(result).
                This step has no ##[group] markers — the ZIP per-step lookup must still succeed.
                If you see .fetchFailed, the unzip subprocess may be sandboxed in this environment.
                """
            )
            return
        }
        #expect(content.contains("Cleaning up orphan processes"))
        #expect(content.contains("Node.js 20 is deprecated"))
        #expect(!content.contains("2026-07-31T"), "Timestamp prefix must be stripped")
    }

    @Test("Prefix match succeeds when ZIP filename differs from step.name")
    func test_sanitisedFilenameDiffers_prefixMatchSucceeds() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/2_Checkout repo", text: "checkout output\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 2, name: "Checkout"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice via prefix match, got \(result)")
            return
        }
        #expect(content.contains("checkout output"))
    }

    @Test("Whitespace-only step content returns .syntheticEmpty")
    func test_emptyContent_returnsSyntheticEmpty() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/2_Checkout", text: "   \n  \n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 2, name: "Checkout"), scope: "owner/repo"
        )
        guard case .syntheticEmpty(let name) = result else {
            Issue.record("Expected .syntheticEmpty, got \(result)")
            return
        }
        #expect(name == "Checkout")
    }

    @Test("ZIP with only top-level blobs returns .flatBlobFallback")
    func test_onlyTopLevelBlobs_returnsFlatBlobFallback() async {
        var fetcher = makeFetcher(
            zipFiles: [(name: "0_release", text: "whole job blob\n")],
            extraResponses: [
                "repos/owner/repo/actions/jobs/1/logs": Data("2026-01-01T00:00:01.000Z ##[group]Checkout\nout\n##[endgroup]\n".utf8),
            ]
        )
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 2, name: "Checkout"), scope: "owner/repo"
        )
        guard case .flatBlobFallback = result else {
            Issue.record("Expected .flatBlobFallback when no per-step files, got \(result)")
            return
        }
    }

    @Test("Job name with / and : is sanitised before ZIP lookup")
    func test_jobNameWithSlashAndColon_sanitised() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "orgactionjob/1_Build", text: "build output\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "org/action:job",
            step: makeStep(number: 1, name: "Build"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice after sanitising job name, got \(result)")
            return
        }
        #expect(content.contains("build output"))
    }

    @Test("Job name > 90 UTF-16 code units is truncated before ZIP lookup")
    func test_jobNameExceeds90UTF16Units_truncated() async {
        let longName  = String(repeating: "a", count: 95)
        let truncated = String(repeating: "a", count: 90)
        var fetcher = makeFetcher(zipFiles: [
            (name: "\(truncated)/1_Build", text: "build output\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: longName,
            step: makeStep(number: 1, name: "Build"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice after UTF-16 truncation, got \(result)")
            return
        }
        #expect(content.contains("build output"))
    }

    @Test("Cache hit: second call for same runID+startedAt makes zero extra network calls")
    func test_cacheHit_zeroAdditionalNetworkCalls() async {
        let transport = StubTransport(responses: [
            "repos/owner/repo/actions/runs/99/logs": Data("ZIP".utf8),
        ])
        var fetcher = LogFetcher(
            transport: transport,
            zipExtractor: { _ in
                .success([
                    (name: "release/2_Checkout", text: "step 2\n"),
                    (name: "release/3_Build",    text: "step 3\n"),
                ])
            }
        )
        _ = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 2, name: "Checkout"), scope: "owner/repo"
        )
        _ = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 1, jobName: "release",
            step: makeStep(number: 3, name: "Build"), scope: "owner/repo"
        )
        #expect(transport.rawCallCount == 1, "ZIP must be fetched exactly once for same runID+startedAt")
    }
}

// MARK: - sanitizeJobNameForZIP tests

@Suite("sanitizeJobNameForZIP")
struct SanitizeJobNameTests {

    @Test("Strips forward slash")
    func test_sanitize_stripsSlash() {
        #expect(sanitizeJobNameForZIP("Build/Test") == "BuildTest")
    }

    @Test("Strips colon")
    func test_sanitize_stripsColon() {
        #expect(sanitizeJobNameForZIP("Deploy: prod") == "Deploy prod")
    }

    @Test("Truncates to 90 UTF-16 code units")
    func test_sanitize_truncatesAt90UTF16() {
        let fortyFive = String(repeating: "\u{1F600}", count: 45)
        let fortySix  = String(repeating: "\u{1F600}", count: 46)
        #expect(sanitizeJobNameForZIP(fortyFive) == fortyFive)
        #expect(sanitizeJobNameForZIP(fortySix).utf16.count == 90)
    }

    @Test("Preserves short plain-ASCII names unchanged")
    func test_sanitize_preservesShortName() {
        #expect(sanitizeJobNameForZIP("Build") == "Build")
        #expect(sanitizeJobNameForZIP("") == "")
    }

    @Test("Drops dangling high surrogate when 90-unit cut splits an emoji pair")
    func test_sanitize_surrogateAtBoundary_dropsHighSurrogate() {
        let input = String(repeating: "a", count: 89) + "🚀"
        let result = sanitizeJobNameForZIP(input)
        #expect(result == String(repeating: "a", count: 89))
        #expect(result.utf16.count == 89)
    }
}
