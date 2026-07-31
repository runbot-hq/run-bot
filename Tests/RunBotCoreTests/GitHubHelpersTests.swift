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
//   user step named "Post <X>" (no Run prefix in group header)
//                                           — test_postPrefixUserStep_matchesSectionNotEpilogue
//   user step named "Post <X>" (Run prefix in group header, stage-2 bypass)
//                                           — test_postPrefixUserStep_matchesSectionViaRunPrefix
//   case-insensitive exact match (stage 1)  — test_exactNameMatch_caseInsensitive
//   no match → full log fallback            — test_noMatch_returnsFullLog
//   unclosed group                          — test_unclosedGroup_stillMatches
//   inter-group lines preserved             — test_interGroupLines_notDropped
//   inter-group lines not duplicated        — test_interGroupLines_noDuplication
//   timestamp stripping                     — test_timestampStripping
//   ANSI stripping                          — test_ansiStripping
//   ANSI + timestamp compose (ANSI-after-Z) — test_ansiAndTimestampCompose
//   CRLF normalisation                      — test_crlfNormalisation
//   bare CR normalisation                   — test_bareCrNormalisation
//   buildParsedLog structural: sections, preamble, epilogue
//                                           — test_buildParsedLog_structure
//   buildParsedLog structural: orphan endgroup discarded
//                                           — test_buildParsedLog_orphanEndgroup_discarded
import Foundation
@testable import GitHubClient
import XCTest

final class GitHubHelpersTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a minimal raw log string with the given named sections and optional
    /// preamble / epilogue lines.
    ///
    /// Timestamps are intentionally omitted: the helper targets parser structure tests.
    /// Tests that exercise the timestamp-stripping pipeline construct their own raw
    /// strings with inline timestamp prefixes (see test_timestampStripping,
    /// test_ansiAndTimestampCompose).
    ///
    /// **Precondition**: if `epilogue` is non-empty, `sections` must also be non-empty.
    /// If `sections` is empty and `epilogue` is non-empty, `buildParsedLog` will never
    /// set `seenFirstGroup`, so epilogue lines will be mis-classified as preamble.
    ///
    /// `assert` (not `precondition`) is used here intentionally: this helper is test-only
    /// code and tests always run in debug mode. `assert` is the correct tool for
    /// test-internal preconditions; `precondition` would be over-engineering for a helper
    /// that can never be called from production code.
    private func makeLog(
        preamble: [String] = [],
        sections: [(name: String, body: [String])] = [],
        epilogue: [String] = []
    ) -> String {
        assert(sections.isEmpty == false || epilogue.isEmpty,
            "makeLog precondition violated: epilogue requires at least one section")
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
        // Tests stage-1 exact match where the step name already contains "Run ".
        // This exercises the case where a user has literally named their step "Run my-step"
        // (as opposed to an action step where the API name is "my-step" and the log group
        // header is "Run my-step" — that case is covered by test_prefixMatch_groupHasRunPrefix).
        // The step name passed here matches the ##[group] header exactly, so stage 1 fires.
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

    func test_exactNameMatch_caseInsensitive() {
        // Stage 1 must match case-insensitively so a step name like "POST DEPLOY" matches
        // a ##[group] header "Post deploy", preventing it from falling through to the
        // stage-3 synthetic epilogue heuristic.
        let raw = makeLog(
            sections: [
                (name: "Post deploy", body: ["deploying to production"]),
                (name: "Run tests", body: ["test output"])
            ],
            epilogue: ["epilogue content"]
        )
        let result = parseStepLog(raw, stepName: "POST DEPLOY", stepNumber: 3, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("deploying to production"),
            "Case-insensitive stage-1 match must find the section")
        XCTAssertFalse(result!.contains("epilogue content"),
            "Stage-3 synthetic heuristic must not fire when stage 1 matched")
        XCTAssertFalse(result!.contains("test output"))
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
        // Verifies that a step named "Post Run actions/checkout@v4" (a GitHub synthetic step)
        // is routed to the epilogue via the stage-3 "post " prefix heuristic.
        //
        // Single-epilogue bucket: the epilogue is intentionally a single flat string for the
        // entire job. GitHub Actions emits no ##[group] markers around synthetic step output,
        // so there is no structured data to separate one post-run step's output from another's.
        // All "Post X" steps therefore show the same epilogue content. This is a known,
        // documented constraint of the ##[group] format (see ParsedLog.epilogue), not a gap
        // in test coverage. A test with multiple post-run steps would assert the same result
        // for each and would not provide additional signal.
        let raw = makeLog(
            sections: [(name: "Run actions/checkout@v4", body: ["checkout output"])],
            epilogue: ["Post-run cleanup line"]
        )
        let result = parseStepLog(raw, stepName: "Post Run actions/checkout@v4", stepNumber: 5, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("Post-run cleanup line"))
        XCTAssertFalse(result!.contains("checkout output"),
            "Synthetic Post-prefix step must return epilogue, not the section body or full log")
    }

    func test_postPrefixUserStep_matchesSectionNotEpilogue() {
        // A real user step named "Post deploy" with a ##[group]Post deploy section must be
        // matched by stage 1 (exact name match) and must NOT be redirected to the epilogue
        // by the stage-3 synthetic heuristic. This guards the ordering guarantee documented
        // in parseStepLog: stages 1–2 run before stage 3.
        let raw = makeLog(
            sections: [
                (name: "Post deploy", body: ["deploying to production"]),
                (name: "Run tests", body: ["test output"])
            ],
            epilogue: ["epilogue content"]
        )
        let result = parseStepLog(raw, stepName: "Post deploy", stepNumber: 3, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("deploying to production"),
            "User step \"Post deploy\" must match its ##[group] section via stage 1")
        XCTAssertFalse(result!.contains("epilogue content"),
            "Stage-3 synthetic heuristic must not fire when stage 1 already matched")
        XCTAssertFalse(result!.contains("test output"))
    }

    func test_postPrefixUserStep_matchesSectionViaRunPrefix() {
        // A real user step named "Post deploy" whose log group header is "Run Post deploy"
        // must be matched by stage 2 (run-prefix normalisation) and must NOT be redirected
        // to the epilogue by the stage-3 synthetic heuristic. This validates the second
        // path through the ordering guarantee: lowerSection == "run post deploy" ==
        // "run " + lowerStep, so stage 2 fires before stage 3 ever runs.
        let raw = makeLog(
            sections: [
                (name: "Run Post deploy", body: ["deploying to production"]),
                (name: "Run tests", body: ["test output"])
            ],
            epilogue: ["epilogue content"]
        )
        let result = parseStepLog(raw, stepName: "Post deploy", stepNumber: 3, logger: nil)
        XCTAssertNotNil(result)
        XCTAssert(result!.contains("deploying to production"),
            "User step \"Post deploy\" must match \"Run Post deploy\" section via stage 2")
        XCTAssertFalse(result!.contains("epilogue content"),
            "Stage-3 synthetic heuristic must not fire when stage 2 already matched")
        XCTAssertFalse(result!.contains("test output"))
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
        // The absent-content assertions below ensure a full-log fallback cannot silently pass.
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
        XCTAssertFalse(result!.contains("step one output"),
                       "Epilogue must not contain section body content")
        XCTAssertFalse(result!.contains("step two output"),
                       "Epilogue must not contain section body content")
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

    // MARK: - buildParsedLog structural tests

    func test_buildParsedLog_structure() {
        // Directly asserts the structural output of buildParsedLog: sections contain only
        // their own body lines, preamble contains only pre-group lines, and epilogue contains
        // both inter-group lines and the post-final-endgroup tail — with no cross-contamination.
        // This is more precise than the black-box tests above, which go through parseStepLog
        // and could survive a refactor that merges or reorders epilogue buckets.
        let cleaned = [
            "preamble line",
            "##[group]Run step-one",
            "step one body",
            "##[endgroup]",
            "inter-group line",
            "##[group]Run step-two",
            "step two body",
            "##[endgroup]",
            "final tail line"
        ].joined(separator: "\n")
        let parsed = buildParsedLog(from: cleaned)

        // Sections
        XCTAssertEqual(parsed.sections.count, 2)
        XCTAssert(parsed.sections[0].name == "Run step-one")
        XCTAssert(parsed.sections[0].body.contains("step one body"))
        XCTAssertFalse(parsed.sections[0].body.contains("inter-group line"),
            "Section body must not contain inter-group lines")
        XCTAssert(parsed.sections[1].name == "Run step-two")
        XCTAssert(parsed.sections[1].body.contains("step two body"))

        // Preamble
        XCTAssert(parsed.preamble.contains("preamble line"))
        XCTAssertFalse(parsed.preamble.contains("step one body"),
            "Preamble must not contain section body content")

        // Epilogue: must contain both inter-group and final-tail lines
        XCTAssert(parsed.epilogue.contains("inter-group line"),
            "Epilogue must contain inter-group lines")
        XCTAssert(parsed.epilogue.contains("final tail line"),
            "Epilogue must contain post-final-endgroup tail")
        XCTAssertFalse(parsed.epilogue.contains("step one body"),
            "Epilogue must not contain section body content")
        XCTAssertFalse(parsed.epilogue.contains("step two body"),
            "Epilogue must not contain section body content")
        XCTAssertFalse(parsed.epilogue.contains("preamble line"),
            "Epilogue must not contain preamble content")
    }

    func test_buildParsedLog_orphanEndgroup_discarded() {
        // An orphan ##[endgroup] (no matching open ##[group]) must be silently discarded:
        // it must not appear in preamble, epilogue, or any section body.
        // This directly asserts the doc-comment contract for the refactored endgroup branch.
        let cleaned = [
            "##[endgroup]",
            "##[group]Run step-one",
            "step one body",
            "##[endgroup]",
            "##[endgroup]"
        ].joined(separator: "\n")
        let parsed = buildParsedLog(from: cleaned)

        XCTAssertEqual(parsed.sections.count, 1)
        XCTAssertFalse(parsed.preamble.contains("##[endgroup]"),
            "Orphan endgroup must not appear in preamble")
        XCTAssertFalse(parsed.epilogue.contains("##[endgroup]"),
            "Orphan endgroup must not appear in epilogue")
        XCTAssertFalse(parsed.sections[0].body.contains("##[endgroup]##[endgroup]"),
            "Only one endgroup marker (the section close) must appear in the section body")
        // The section's own closing ##[endgroup] is included in the body by design — verify
        // it appears exactly once.
        let endgroupCount = parsed.sections[0].body
            .components(separatedBy: "##[endgroup]").count - 1
        XCTAssertEqual(endgroupCount, 1,
            "Section body must contain exactly one ##[endgroup] (the section close)")
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
        // Exercises the ANSI-after-Z edge case: an ANSI escape sequence sitting between
        // the timestamp Z and the log content, e.g. "2026-...Z \u{1B}[32moutput\u{1B}[0m".
        // This is the specific case the [^\S\n]* trailer in timestampRegex defends against:
        // after stripAnsi removes the escape following Z, the timestamp regex must still
        // match and strip the prefix cleanly.
        // Pipeline: CR → stripAnsi → stripTimestamps → buildParsedLog.
        // After stripAnsi: "2026-07-29T03:11:15.0000000Z ##[group]Run step"
        //                  "2026-07-29T03:11:16.0000000Z coloured output"
        //                  "2026-07-29T03:11:16.0000001Z ##[endgroup]"
        // After stripTimestamps: "##[group]Run step" / "coloured output" / "##[endgroup]"
        let esc = "\u{001B}"
        let raw = [
            "2026-07-29T03:11:15.0000000Z ##[group]Run step",
            "2026-07-29T03:11:16.0000000Z \(esc)[32mcoloured output\(esc)[0m",
            "2026-07-29T03:11:16.0000001Z ##[endgroup]"
        ].joined(separator: "\n")
        let result = parseStepLog(raw, stepName: "Run step", stepNumber: 1, logger: nil)
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.contains("2026-"),
            "Timestamp prefix must be stripped from all lines")
        XCTAssertFalse(result!.contains(esc),
            "ANSI escape sequences must be stripped")
        XCTAssert(result!.contains("coloured output"),
            "Content must survive both stripping passes")
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
