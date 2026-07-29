// GitHubHelpersTests.swift
// RunBotCoreTests
import XCTest

/// Unit tests for the log-cleaning helpers in GitHubHelpers.swift.
/// These test the private functions indirectly through `fetchStepLog` behaviour
/// or via internal-access if `@testable import GitHubClient` is available.
///
/// The core invariants being tested:
/// 1. RFC 3339 timestamp prefixes are stripped from every line.
/// 2. ANSI escape sequences are stripped.
/// 3. Both passes compose correctly.
/// 4. Clean strings pass through unchanged.
final class GitHubHelpersTests: XCTestCase {

    // MARK: - Timestamp stripping

    func test_stripTimestamps_removesPrefix() {
        let raw = """
            2026-07-29T03:11:15.4722230Z Cleaning up orphan processes
            2026-07-29T03:11:16.3185700Z Warning: Node.js 20 is deprecated.
            """
        let result = stripTimestamps(raw)
        XCTAssertFalse(result.contains("2026-07-29T"), "Timestamp prefix should be removed")
        XCTAssertTrue(result.contains("Cleaning up orphan processes"))
        XCTAssertTrue(result.contains("Warning: Node.js 20 is deprecated."))
    }

    func test_stripTimestamps_noOp_whenNoTimestamps() {
        let plain = "Cleaning up orphan processes\nAll good."
        XCTAssertEqual(stripTimestamps(plain), plain, "String without timestamps should be unchanged")
    }

    func test_stripTimestamps_doesNotStripMidLineTimestamps() {
        // A timestamp that appears mid-line (e.g. in user output) should NOT be stripped.
        let line = "Build completed at 2026-07-29T03:11:15.4722230Z successfully"
        XCTAssertEqual(stripTimestamps(line), line, "Mid-line timestamps should not be stripped")
    }

    // MARK: - ANSI stripping

    func test_stripAnsi_removesEscapeSequences() {
        let raw = "\u{001B}[31mError: build failed\u{001B}[0m"
        let result = stripAnsi(raw)
        XCTAssertEqual(result, "Error: build failed")
    }

    func test_stripAnsi_noOp_whenNoEscapes() {
        let plain = "No colour here."
        XCTAssertEqual(stripAnsi(plain), plain)
    }

    // MARK: - Composed pipeline (mirrors parseStepLog order)

    func test_stripTimestampsAfterStripAnsi_combined() {
        let raw = "2026-07-29T03:11:15.4722230Z \u{001B}[31mError: build failed\u{001B}[0m"
        let result = stripTimestamps(stripAnsi(raw))
        XCTAssertEqual(result, "Error: build failed")
    }

    func test_pipeline_plainString_unchanged() {
        let plain = "Cleaning up orphan processes"
        let result = stripTimestamps(stripAnsi(plain))
        XCTAssertEqual(result, plain)
    }
}
