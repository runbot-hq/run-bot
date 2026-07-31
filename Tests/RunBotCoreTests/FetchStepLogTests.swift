// FetchStepLogTests.swift
// RunBotCoreTests
//
// Tests for LogFetcher.fetchStepLog.
//
// The ZipExtractor closure is injected so these tests never touch the filesystem
// via ProcessRunner, which the test-sandbox blocks. Tests inject a closure that
// returns pre-built tuples directly — no subprocess, no filesystem.
//
// The exception is `test_completeJob_regression2358_realExtractor`, which uses
// the real ZipExtractor against the shared fixture ZIP from TestFixtures.swift.
// That test uses withKnownIssue(isIntermittent: true, when: { !unzipBinaryExists })
// so sandboxed CI records an expected issue rather than a hard failure or silent pass.
//
// Coverage map:
//   Normal step — ANSI + timestamp stripped                  — test_normalStep_returnsSlice
//   Regression #2358 — synthetic "Complete job" step (stub)  — test_completeJob_regression2358
//   Regression #2358 — real extractor against fixture ZIP    — test_completeJob_regression2358_realExtractor
//   Prefix match when filename differs from step.name        — test_sanitisedFilenameDiffers_prefixMatchSucceeds
//   Whitespace-only content → .syntheticEmpty                — test_emptyContent_returnsSyntheticEmpty
//   Only top-level blobs (no '/') → .flatBlobFallback        — test_onlyTopLevelBlobs_returnsFlatBlobFallback
//   Job name with / and : sanitised                          — test_jobNameWithSlashAndColon_sanitised
//   Job name > 90 UTF-16 code units truncated                — test_jobNameExceeds90UTF16Units_truncated
//   Cache hit: zero extra network calls                      — test_cacheHit_zeroAdditionalNetworkCalls

import Foundation
import Testing
@testable import RunBotCore

// MARK: - StubTransport

private final class StubTransport: GitHubTransporting, @unchecked Sendable {
    let responses: [String: Data]
    private(set) var rawCallCount = 0
    init(responses: [String: Data]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        rawCallCount += 1
        let url = request.url?.absoluteString ?? ""
        for (key, data) in responses where url.contains(key) {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: nil, headerFields: nil)!
            return (data, response)
        }
        throw URLError(.badServerResponse)
    }
}

private func makeStep(number: Int, name: String) -> GitHubStep {
    GitHubStep(
        number: number,
        name: name,
        status: .completed,
        conclusion: .success,
        startedAt: nil,
        completedAt: nil
    )
}

/// Builds a `LogFetcher` with a stub transport and a no-subprocess extractor.
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
    return LogFetcher(transport: transport, zipExtractor: { _ in .success(zipFiles) })
}

@Suite("LogFetcher.fetchStepLog")
struct FetchStepLogTests {

    @Test("Normal step: returns .slice with ANSI and timestamps stripped")
    func test_normalStep_returnsSlice() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/1_Checkout",
             text: "2026-01-01T00:00:01.000Z \u{1B}[32mcheckout output\u{1B}[0m\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: nil,
            jobID: 42, jobName: "release",
            step: makeStep(number: 1, name: "Checkout"),
            scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice, got \(result)")
            return
        }
        #expect(content.contains("checkout output"))
        #expect(!content.contains("2026-"), "Timestamps must be stripped")
        #expect(!content.contains("\u{1B}"), "ANSI codes must be stripped")
    }

    @Test("Regression #2358: synthetic Complete job step returns .slice, not .syntheticEmpty")
    func test_completeJob_regression2358() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/2_Checkout", text: "checkout output\n"),
            (name: "release/7_Complete job", text: "Cleaning up orphan processes\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: nil,
            jobID: 42, jobName: "release",
            step: makeStep(number: 7, name: "Complete job"), scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("REGRESSION #2358: Expected .slice for synthetic step, got \(result)")
            return
        }
        #expect(content.contains("Cleaning up orphan processes"))
    }

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
        withKnownIssue(
            "unzip subprocess unavailable (sandboxed CI runner)",
            isIntermittent: true
        ) {
            guard case .slice(let content) = result else {
                Issue.record("REGRESSION #2358 (real extractor): Expected .slice for 'Complete job', got \(result). This step has no ##[group] markers — the ZIP per-step lookup must still succeed.")
                return
            }
            #expect(content.contains("Cleaning up orphan processes"))
            #expect(content.contains("Node.js 20 is deprecated"))
            #expect(!content.contains("2026-07-31T"), "Timestamp prefix must be stripped")
        } when: {
            !unzipBinaryExists
        }
    }

    @Test("Prefix match succeeds when ZIP filename differs from step.name")
    func test_sanitisedFilenameDiffers_prefixMatchSucceeds() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/1_Checkout", text: "checkout output\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: nil,
            jobID: 42, jobName: "release",
            step: makeStep(number: 1, name: "actions/checkout@v4"),
            scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice, got \(result)")
            return
        }
        #expect(content.contains("checkout output"))
    }

    @Test("Whitespace-only step content returns .syntheticEmpty")
    func test_emptyContent_returnsSyntheticEmpty() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "release/1_Checkout", text: "   \n  \n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: nil,
            jobID: 42, jobName: "release",
            step: makeStep(number: 1, name: "Checkout"),
            scope: "owner/repo"
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
            runID: 99, startedAt: nil,
            jobID: 1, jobName: "release",
            step: makeStep(number: 1, name: "Checkout"),
            scope: "owner/repo"
        )
        guard case .flatBlobFallback = result else {
            Issue.record("Expected .flatBlobFallback, got \(result)")
            return
        }
    }

    @Test("Job name with / and : is sanitised before ZIP lookup")
    func test_jobNameWithSlashAndColon_sanitised() async {
        var fetcher = makeFetcher(zipFiles: [
            (name: "orgactionjob/1_Build", text: "build output\n"),
        ])
        let result = await fetcher.fetchStepLog(
            runID: 99, startedAt: nil,
            jobID: 42, jobName: "org/action:job",
            step: makeStep(number: 1, name: "Build"),
            scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice, got \(result)")
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
            runID: 99, startedAt: nil,
            jobID: 42, jobName: longName,
            step: makeStep(number: 1, name: "Build"),
            scope: "owner/repo"
        )
        guard case .slice(let content) = result else {
            Issue.record("Expected .slice, got \(result)")
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
            zipExtractor: { _ in .success([(name: "release/1_Build", text: "build output\n")]) }
        )
        _ = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 42, jobName: "release",
            step: makeStep(number: 1, name: "Build"),
            scope: "owner/repo"
        )
        let callsAfterFirst = transport.rawCallCount
        _ = await fetcher.fetchStepLog(
            runID: 99, startedAt: "2026-01-01T00:00:00Z",
            jobID: 42, jobName: "release",
            step: makeStep(number: 1, name: "Build"),
            scope: "owner/repo"
        )
        #expect(transport.rawCallCount == callsAfterFirst,
            "Cache hit must make zero additional network calls")
    }
}

// MARK: - sanitizeJobNameForZIP

@Suite("sanitizeJobNameForZIP")
struct SanitizeJobNameTests {

    @Test("Preserves short plain-ASCII names unchanged")
    func test_sanitize_preservesShortAscii() {
        #expect(sanitizeJobNameForZIP("release") == "release")
        #expect(sanitizeJobNameForZIP("build-test") == "build-test")
    }

    @Test("Strips forward slash")
    func test_sanitize_stripsSlash() {
        #expect(sanitizeJobNameForZIP("org/repo") == "orgrepo")
    }

    @Test("Strips colon")
    func test_sanitize_stripsColon() {
        #expect(sanitizeJobNameForZIP("action:job") == "actionjob")
    }

    @Test("Truncates to 90 UTF-16 code units")
    func test_sanitize_truncatesAt90UTF16() {
        let fortyFive = String(repeating: "\u{1F600}", count: 45)
        let fortySix  = String(repeating: "\u{1F600}", count: 46)
        #expect(sanitizeJobNameForZIP(fortyFive) == fortyFive)
        #expect(sanitizeJobNameForZIP(fortySix).utf16.count == 90)
    }

    @Test("Preserves empty string")
    func test_sanitize_preservesEmpty() {
        #expect(sanitizeJobNameForZIP("") == "")
    }

    @Test("Drops dangling high surrogate when 90-unit cut splits an emoji pair")
    func test_sanitize_surrogateAtBoundary_dropsHighSurrogate() {
        let input = String(repeating: "a", count: 89) + "🚀"
        let result = sanitizeJobNameForZIP(input)
        #expect(result == String(repeating: "a", count: 89),
            "Dangling high surrogate must be dropped to keep valid UTF-16")
    }
}
