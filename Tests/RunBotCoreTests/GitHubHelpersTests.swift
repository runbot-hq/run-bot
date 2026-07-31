// GitHubHelpersTests.swift
// RunBotCoreTests
//
// Tests for the cleaning pipeline (cleanLogText) in GitHubHelpers.swift.
//
// ## What was deleted and why
// All parseStepLog / buildParsedLog tests that used the synthetic makeLog()
// helper have been removed. parseStepLog is now fallback-only after #2362:
// the primary code path fetches per-step files from the run ZIP and never
// calls parseStepLog. Tests for parseStepLog's ##[group] parsing logic no
// longer reflect any real production path and were deleted to avoid
// maintaining tests that can pass while the production path fails.
//
// Kept: the cleaning pipeline tests (timestamp stripping, ANSI stripping,
// CRLF normalisation) because cleanLogText() is still exercised on every
// step log fetch in the ZIP path.
//
// Coverage map:
//   timestamp stripping                     — test_timestampStripping
//   ANSI stripping                          — test_ansiStripping
//   ANSI + timestamp compose (ANSI-after-Z) — test_ansiAndTimestampCompose
//   CRLF normalisation                      — test_crlfNormalisation
//   bare CR normalisation                   — test_bareCrNormalisation
import Foundation
@testable import GitHubClient
import XCTest

final class GitHubHelpersTests: XCTestCase {

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
