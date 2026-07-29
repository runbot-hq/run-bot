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
import Foundation
import GitHubClient
import Testing

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

@Suite("fetchStepLog timestamp stripping")
struct GitHubHelpersTests {

    // MARK: Timestamp stripping

    /// Happy path: line-start timestamps are stripped, content is preserved.
    @Test func fetchStepLog_stripsTimestampPrefixes() async throws {
        let transport = MockTransport()
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z Cleaning up orphan processes",
            "2026-07-29T03:11:16.3185700Z Warning: Node.js 20 is deprecated."
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 1, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("2026-07-29T"), "Returned log should not contain RFC 3339 timestamp prefixes")
        #expect(result.contains("Cleaning up orphan processes"), "Log content should be preserved after stripping")
        #expect(result.contains("Warning: Node.js 20 is deprecated."), "Log content should be preserved after stripping")
    }

    /// Guards the `.anchorsMatchLines` behaviour: a timestamp that appears mid-line
    /// inside log content (not at the start of a line) must NOT be stripped.
    /// Uses a ##[group] wrapper so parseStepLog exercises the section-slicing path,
    /// not the sections.isEmpty fallback — this directly guards the anchor constraint.
    @Test func fetchStepLog_midLineTimestamp_preserved() async throws {
        let transport = MockTransport()
        let midLineContent = "Error occurred at 2026-07-29T03:11:15.4722230Z during build"
        let rawLog = [
            "2026-07-29T03:11:15.4000000Z ##[group]Build step",
            "2026-07-29T03:11:15.4722230Z \(midLineContent)",
            "2026-07-29T03:11:15.5000000Z ##[endgroup]"
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 2, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(
            result.contains("2026-07-29T03:11:15.4722230Z during build"),
            "A timestamp embedded mid-line in log content must not be stripped"
        )
    }

    /// Verifies stripTimestamps is a no-op on content that has no timestamp prefixes.
    /// Uses a ##[group]-wrapped payload so parseStepLog takes the section-slicing path
    /// rather than the no-group fallback — making it explicit that clean content is
    /// not corrupted regardless of which branch executes.
    @Test func fetchStepLog_cleanContent_notCorrupted() async throws {
        let transport = MockTransport()
        let cleanLine = "Cleaning up orphan processes"
        // Wrap in a ##[group] block so buildLogSections finds exactly one section.
        // stepNumber: 1 therefore selects this section directly.
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z ##[group]Post job cleanup",
            "2026-07-29T03:11:15.5000000Z \(cleanLine)",
            "2026-07-29T03:11:15.6000000Z ##[endgroup]"
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 3, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(result.contains(cleanLine), "Clean log content must survive the stripping pipeline unchanged")
        #expect(!result.contains("2026-07-29T"), "Timestamp prefixes must still be stripped from the selected section")
    }

    /// Verifies that a blank timestamped line with no trailing space is also stripped.
    /// This exercises the `[ ]?` optional-space trailer in timestampRegex.
    @Test func fetchStepLog_bareTimestampLine_stripped() async throws {
        let transport = MockTransport()
        let rawLog = [
            "2026-07-29T03:11:15.0000000Z",
            "2026-07-29T03:11:15.1000000Z Actual content here"
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 7, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("2026-07-29T"), "Bare timestamp-only lines must also be stripped")
        #expect(result.contains("Actual content here"), "Content on subsequent lines must be preserved")
    }

    // MARK: ANSI stripping (regression guard)

    @Test func fetchStepLog_stripsAnsiEscapeCodes() async throws {
        let transport = MockTransport()
        let rawLog = "2026-07-29T03:11:15.4722230Z \u{001B}[31mError: build failed\u{001B}[0m"
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 4, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("\u{001B}["), "ANSI escape sequences should be stripped")
        #expect(result.contains("Error: build failed"), "Log content should survive ANSI stripping")
    }

    // MARK: Edge cases

    @Test func fetchStepLog_returnsNil_forOrgScope() async {
        let transport = MockTransport()
        // org-scoped logs are not supported — fetchStepLog should return nil early.
        transport.stubRawData = Data("some log".utf8)
        let result = await fetchStepLog(jobID: 5, stepNumber: 1, scope: "runbot-hq", transport: transport)
        #expect(result == nil, "fetchStepLog should return nil for org-only scope")
    }

    @Test func fetchStepLog_returnsNil_whenTransportReturnsNil() async {
        let transport = MockTransport()
        transport.stubRawData = nil
        let result = await fetchStepLog(jobID: 6, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport)
        #expect(result == nil, "fetchStepLog should return nil when transport returns nil")
    }
}
