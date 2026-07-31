// GitHubHelpersTests.swift
// RunBotCoreTests
//
// Tests for the cleanLogText pipeline in GitHubHelpers.swift.
//
// ## What was deleted and why
// All parseStepLog / buildParsedLog tests that used the synthetic makeLog()
// helper have been removed. parseStepLog is now fallback-only after #2362:
// the primary code path fetches per-step files from the run ZIP and never
// calls parseStepLog. Tests for its ##[group] parsing logic no longer reflect
// any real production path and were deleted to avoid maintaining tests that
// pass while the production path fails.
//
// ## What is tested here
// cleanLogText() directly — the timestamp stripping, ANSI stripping, and
// line-ending normalisation pipeline that runs on every ZIP-path log fetch.
// These tests call cleanLogText in isolation, not through parseStepLog.
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

    // MARK: - cleanLogText pipeline

    func test_timestampStripping() {
        let raw = "2026-07-29T03:11:15.4722230Z output line\n2026-07-29T03:11:16.0000000Z second line"
        let result = cleanLogText(raw)
        XCTAssertFalse(result.contains("2026-"), "Timestamp prefix must be stripped")
        XCTAssert(result.contains("output line"))
        XCTAssert(result.contains("second line"))
    }

    func test_ansiStripping() {
        let esc = "\u{001B}"
        let raw = "\(esc)[32mGreen text\(esc)[0m\nplain line"
        let result = cleanLogText(raw)
        XCTAssertFalse(result.contains(esc), "ANSI escape sequences must be stripped")
        XCTAssert(result.contains("Green text"))
        XCTAssert(result.contains("plain line"))
    }

    func test_ansiAndTimestampCompose() {
        // Exercises the ANSI-after-Z edge case: ANSI escape sitting between the
        // timestamp Z and the log content. After stripAnsi removes the escape,
        // the timestamp regex must still match and strip the prefix cleanly.
        // Pipeline order: CRLF → stripAnsi → stripTimestamps.
        let esc = "\u{001B}"
        let raw = "2026-07-29T03:11:16.0000000Z \(esc)[32mcoloured output\(esc)[0m"
        let result = cleanLogText(raw)
        XCTAssertFalse(result.contains("2026-"),
            "Timestamp prefix must be stripped")
        XCTAssertFalse(result.contains(esc),
            "ANSI escape sequences must be stripped")
        XCTAssert(result.contains("coloured output"),
            "Content must survive both stripping passes")
    }

    func test_crlfNormalisation() {
        let raw = "line one\r\nline two\r\nline three"
        let result = cleanLogText(raw)
        XCTAssert(result.contains("line one"))
        XCTAssert(result.contains("line two"))
        XCTAssertFalse(result.contains("\r"), "CRLF must be normalised to LF")
    }

    func test_bareCrNormalisation() {
        let raw = "line one\rline two\rline three"
        let result = cleanLogText(raw)
        XCTAssert(result.contains("line one"))
        XCTAssert(result.contains("line two"))
        XCTAssertFalse(result.contains("\r"), "Bare CR must be normalised")
    }
}
