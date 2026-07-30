// GitHubHelpersTests.swift
// RunBotCoreTests
//
// Tests for parseStepLog / buildParsedLog in GitHubHelpers.swift.
//
// Coverage map:
//   exact name match                        — test_exactNameMatch
//   prefix match ("Run X" vs X)             — test_prefixMatch_groupHasRunPrefix
//   run-prefix does not over-match          — test_runPrefixDoesNotMatchUnrelated
//   synthetic: Set up job                   — test_setUpJob_returnsPreamble
//   synthetic: Complete job                 — test_completeJob_returnsEpilogue
//   synthetic: Post Run X                   — test_postRunStep_returnsEpilogue
//   no match → full log fallback            — test_noMatch_returnsFullLog
//   unclosed group                          — test_unclosedGroup_stillMatches
//   inter-group lines preserved             — test_interGroupLines_notDropped
//   inter-group lines not duplicated        — test_interGroupLines_noDuplication
//   timestamp stripping                     — test_timestampStripping
//   ANSI stripping                          — test_ansiStripping
//   ANSI + timestamp compose                — test_ansiAndTimestampCompose
//   CRLF normalisation                      — test_crlfNormalisation
//   bare CR normalisation                   — test_bareCrNormalisation
import Foundation
@testable import GitHubClient
import XCTest

final class GitHubHelpersTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal raw log string with the given named sections and optional
    /// preamble / epilogue lines. Timestamps are omitted — tests that need them
    /// inject their own raw strings.
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

    // MARK: - Name-based lookup

    func test_exactNameMatch() {
        let raw = makeLog(
            sections: [
                (name: "Run actions/checkout@v4", body: ["Checking out repo"]),
                (name: "Run my-step", body: ["Hello from my-step"])
            ]
        )
        let result = parseStepLog(raw, stepName: "Run my-step", stepNumber: 99, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Run my-step"))
        XCTAssert(result!.contains("Hello from my-step"))
        XCTAssertFalse(result!.contains("Checking out repo"))
    }

    func test_prefixMatch_groupHasRunPrefix() {
        // step.name from the API: "actions/checkout@v4"
        // ##[group] header in the log: "Run actions/checkout@v4"
        // The "Run "-normalisation in step 2 must bridge this gap.
        // A second unrelated section is included so that returning the full log
        // (i.e. a failure to match) would cause the final XCTAssertFalse to fail.
        let raw = makeLog(
            sections: [
                (name: "Run actions/checkout@v4", body: ["Fetching the repository"]),
                (name: "Run build", body: ["unrelated build output"])
            ]
        )
        let result = parseStepLog(raw, stepName: "actions/checkout@v4", stepNumber: 2, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Fetching the repository"))
        XCTAssertFalse(result!.contains("unrelated build output"),
            "Run-prefix match must return only the matched section, not the full log")
    }

    func test_runPrefixDoesNotMatchUnrelated() {
        // "Build" as a step name must not match a section named "Build documentation".
        // The normalisation checks only exact equality with and without the "Run " prefix.
        let raw = makeLog(
            sections: [
                (name: "Build documentation", body: ["docs output"]),
                (name: "Run tests", body: ["test output"])
            ]
        )
        let result = parseStepLog(raw, stepName: "Build", stepNumber: 3, logger: nil)
        // "Build" does not exactly equal "Build documentation" or "Run Build",
        // so it should fall through to the full-log fallback.
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("docs output"),
            "Fallback should return full log, not a false prefix match")
        XCTAssert(result!.contains("test output"))
    }

    func test_setUpJob_returnsPreamble() {
        let raw = makeLog(
            preamble: ["Current runner version: '2.x'", "Operating System"],
            sections: [(name: "Run some-action", body: ["doing work"])]
        )
        let result = parseStepLog(raw, stepName: "Set up job", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Current runner version"))
        XCTAssertFalse(result!.contains("doing work"))
    }

    func test_completeJob_returnsEpilogue() {
        let raw = makeLog(
            sections: [(name: "Run some-action", body: ["doing work"])],
            epilogue: ["Cleaning up orphan processes", "Warning: Node.js 20 is deprecated."]
        )
        let result = parseStepLog(raw, stepName: "Complete job", stepNumber: 99, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Cleaning up orphan processes"))
        XCTAssertFalse(result!.contains("doing work"))
    }

    func test_postRunStep_returnsEpilogue() {
        let raw = makeLog(
            sections: [(name: "Run actions/checkout@v4", body: ["checkout output"])],
            epilogue: ["Post-run cleanup line"]
        )
        let result = parseStepLog(raw, stepName: "Post Run actions/checkout@v4", stepNumber: 5, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Post-run cleanup line"))
    }

    func test_noMatch_returnsFullLog() {
        let raw = makeLog(
            sections: [(name: "Run some-action", body: ["output"])]
        )
        let result = parseStepLog(raw, stepName: "Nonexistent Step", stepNumber: 3, logger: nil)
        XCTAssertNotNil(result)
        // Full log contains everything
        XCTAssert(result!.contains("##[group]Run some-action"))
        XCTAssert(result!.contains("output"))
    }

    func test_unclosedGroup_stillMatches() {
        // Malformed log: ##[group] with no ##[endgroup]
        let raw = "##[group]Run broken-step\nsome output line"
        let result = parseStepLog(raw, stepName: "Run broken-step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("some output line"))
    }

    func test_interGroupLines_notDropped() {
        // Lines between ##[endgroup] and the next ##[group] must not be silently discarded.
        // They should appear in the epilogue and therefore be visible when "Complete job" is tapped.
        let raw = [
            "##[group]Run step-one",
            "step one output",
            "##[endgroup]",
            "runner annotation between groups",
            "##[group]Run step-two",
            "step two output",
            "##[endgroup]",
            "final cleanup line"
        ].joined(separator: "\n")
        let result = parseStepLog(raw, stepName: "Complete job", stepNumber: 99, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("runner annotation between groups"),
                  "Inter-group lines must not be dropped")
        XCTAssert(result!.contains("final cleanup line"))
    }

    func test_interGroupLines_noDuplication() {
        // The final tail (after the last ##[endgroup]) must appear exactly once in the epilogue.
        // A previous bug concatenated interGroupLines with a post-loop lastEndgroupIdx slice,
        // causing lines that were already in interGroupLines to be appended a second time.
        let raw = [
            "##[group]Run step-one",
            "step one output",
            "##[endgroup]",
            "inter-group annotation",
            "##[group]Run step-two",
            "step two output",
            "##[endgroup]",
            "final cleanup line"
        ].joined(separator: "\n")
        let result = parseStepLog(raw, stepName: "Complete job", stepNumber: 99, logger: nil)
        XCTAssertNotNil(result)
        let text = result!
        // Each distinct line must appear exactly once.
        let annotationCount = text.components(separatedBy: "inter-group annotation").count - 1
        let finalCount = text.components(separatedBy: "final cleanup line").count - 1
        XCTAssertEqual(annotationCount, 1, "inter-group annotation must appear exactly once")
        XCTAssertEqual(finalCount, 1, "final cleanup line must appear exactly once")
    }

    // MARK: - Cleaning pipeline

    func test_timestampStripping() {
        let raw = "2026-07-29T03:11:15.4722230Z ##[group]Run step\n2026-07-29T03:11:16.0000000Z output line\n2026-07-29T03:11:16.0000001Z ##[endgroup]"
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("2026-"))
        XCTAssert(result!.contains("output line"))
    }

    func test_ansiStripping() {
        let esc = "\u{001B}"
        let raw = "##[group]Run step\n\(esc)[32mGreen text\(esc)[0m\n##[endgroup]"
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains(esc))
        XCTAssert(result!.contains("Green text"))
    }

    func test_ansiAndTimestampCompose() {
        let esc = "\u{001B}"
        let raw = "2026-07-29T03:11:15.0000000Z \(esc)[32m##[group]Run step\(esc)[0m\n2026-07-29T03:11:16.0000000Z output\n2026-07-29T03:11:16.0000001Z ##[endgroup]"
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("2026-"))
        XCTAssertFalse(result!.contains(esc))
        XCTAssert(result!.contains("output"))
    }

    func test_crlfNormalisation() {
        let raw = "##[group]Run step\r\noutput line\r\n##[endgroup]"
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("output line"))
        XCTAssertFalse(result!.contains("\r"))
    }

    func test_bareCrNormalisation() {
        let raw = "##[group]Run step\routput line\r##[endgroup]"
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("output line"))
        XCTAssertFalse(result!.contains("\r"))
    }
}
