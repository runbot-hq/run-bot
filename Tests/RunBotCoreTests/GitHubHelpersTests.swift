// GitHubHelpersTests.swift
// RunBotCoreTests
//
// Tests the timestamp-stripping behaviour introduced in #2330 by driving
// the public `fetchStepLog(jobID:stepNumber:scope:transport:)` entry point
// with a `MockTransport` that returns a controlled raw log body.
//
// `stripTimestamps` and `stripAnsi` are private file-scope functions inside
// GitHubHelpers.swift and are therefore not accessible even with
// `@testable import GitHubClient` — @testable only opens `internal`, not
// `private`. All assertions go through the public API instead.
import GitHubClient
import XCTest

// MARK: - Mock transport

/// Minimal `GitHubTransportProtocol` conformer for unit tests.
/// `raw(_:timeout:)` returns `stubRawData`; all other methods return nil / false.
final class MockTransport: GitHubTransportProtocol, @unchecked Sendable {
    let decoder: JSONDecoder = JSONDecoder()
    let logger: (any GitHubLogger)? = nil
    /// The raw bytes that `raw(_:timeout:)` will return. Set before calling `fetchStepLog`.
    var stubRawData: Data?

    func raw(_ endpoint: String, timeout: TimeInterval) async -> Data? { stubRawData }
    func apiAsync(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func apiPaginated(_ endpoint: String, timeout: TimeInterval) async -> Data? { nil }
    func post(_ endpoint: String, body: Data?, timeout: TimeInterval) async -> Data? { nil }
    func put(_ endpoint: String, body: Data, timeout: TimeInterval) async -> Data? { nil }
    func delete(_ endpoint: String, timeout: TimeInterval) async -> Bool { false }
    func cancelRun(runID: Int, scope: String) async -> Bool { false }
    func patchRunnerLabels(scope: String, runnerID: Int, labels: [String]) async -> [String]? { nil }
    func fetchRegistrationToken(scope: String) async -> String? { nil }
    func fetchRemovalToken(scope: String) async -> String? { nil }
    func deleteRunnerByID(scope: String, runnerID: Int) async -> Bool { false }
}

// MARK: - Tests

final class GitHubHelpersTests: XCTestCase {

    private let transport = MockTransport()
    /// A valid `owner/repo` scope string — required for `fetchStepLog` to not early-exit.
    private let scope = "runbot-hq/run-bot"

    // MARK: Timestamp stripping

    /// Happy path: line-start timestamps are stripped, content is preserved.
    func test_fetchStepLog_stripsTimestampPrefixes() async {
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z Cleaning up orphan processes",
            "2026-07-29T03:11:16.3185700Z Warning: Node.js 20 is deprecated."
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 1, stepNumber: 1, scope: scope, transport: transport)

        XCTAssertNotNil(result, "fetchStepLog should return non-nil for valid log")
        XCTAssertFalse(
            result?.contains("2026-07-29T") ?? false,
            "Returned log should not contain RFC 3339 timestamp prefixes"
        )
        XCTAssertTrue(
            result?.contains("Cleaning up orphan processes") ?? false,
            "Log content should be preserved after stripping"
        )
        XCTAssertTrue(
            result?.contains("Warning: Node.js 20 is deprecated.") ?? false,
            "Log content should be preserved after stripping"
        )
    }

    /// Guards the `.anchorsMatchLines` behaviour: a timestamp that appears mid-line
    /// inside log content (not at the start of a line) must NOT be stripped.
    /// This is the only assertion that directly exercises the anchor constraint on
    /// `timestampRegex` — a regression here would mean content timestamps get eaten.
    func test_fetchStepLog_midLineTimestamp_preserved() async {
        let midLineContent = "Error occurred at 2026-07-29T03:11:15.4722230Z during build"
        let rawLog = "2026-07-29T03:11:15.4722230Z \(midLineContent)"
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 2, stepNumber: 1, scope: scope, transport: transport)

        XCTAssertTrue(
            result?.contains("2026-07-29T03:11:15.4722230Z during build") ?? false,
            "A timestamp embedded mid-line in log content must not be stripped"
        )
    }

    /// Verifies stripTimestamps is a no-op on content that has no timestamp prefixes.
    /// Uses a ##[group]-wrapped payload so parseStepLog takes the section-slicing path
    /// rather than the no-group fallback — making it explicit that clean content is
    /// not corrupted regardless of which branch executes.
    func test_fetchStepLog_cleanContent_notCorrupted() async {
        let cleanLine = "Cleaning up orphan processes"
        // Wrap in a ##[group] block so buildLogSections finds exactly one section.
        // stepNumber: 1 therefore selects this section directly.
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z ##[group]Post job cleanup",
            "2026-07-29T03:11:15.5000000Z \(cleanLine)",
            "2026-07-29T03:11:15.6000000Z ##[endgroup]"
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 3, stepNumber: 1, scope: scope, transport: transport)

        XCTAssertTrue(
            result?.contains(cleanLine) ?? false,
            "Clean log content must survive the stripping pipeline unchanged"
        )
        XCTAssertFalse(
            result?.contains("2026-07-29T") ?? false,
            "Timestamp prefixes must still be stripped from the selected section"
        )
    }

    // MARK: ANSI stripping (regression guard)

    func test_fetchStepLog_stripsAnsiEscapeCodes() async {
        let rawLog = "2026-07-29T03:11:15.4722230Z \u{001B}[31mError: build failed\u{001B}[0m"
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 4, stepNumber: 1, scope: scope, transport: transport)

        XCTAssertFalse(
            result?.contains("\u{001B}[") ?? false,
            "ANSI escape sequences should be stripped"
        )
        XCTAssertTrue(
            result?.contains("Error: build failed") ?? false,
            "Log content should survive ANSI stripping"
        )
    }

    // MARK: Edge cases

    func test_fetchStepLog_returnsNil_forOrgScope() async {
        // org-scoped logs are not supported — fetchStepLog should return nil early.
        transport.stubRawData = Data("some log".utf8)
        let result = await fetchStepLog(jobID: 5, stepNumber: 1, scope: "runbot-hq", transport: transport)
        XCTAssertNil(result, "fetchStepLog should return nil for org-only scope")
    }

    func test_fetchStepLog_returnsNil_whenTransportReturnsNil() async {
        transport.stubRawData = nil
        let result = await fetchStepLog(jobID: 6, stepNumber: 1, scope: scope, transport: transport)
        XCTAssertNil(result, "fetchStepLog should return nil when transport returns nil")
    }
}
