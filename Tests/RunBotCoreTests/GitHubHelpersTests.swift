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

    func raw(_ _: String, timeout _: TimeInterval) async -> Data? { stubRawData }
    func apiAsync(_ _: String, timeout _: TimeInterval) async -> Data? { nil }
    func apiPaginated(_ _: String, timeout _: TimeInterval) async -> Data? { nil }
    func post(_ _: String, body _: Data?, timeout _: TimeInterval) async -> Data? { nil }
    func put(_ _: String, body _: Data, timeout _: TimeInterval) async -> Data? { nil }
    func delete(_ _: String, timeout _: TimeInterval) async -> Bool { false }
    func cancelRun(runID _: Int, scope _: String) async -> Bool { false }
    func patchRunnerLabels(scope _: String, runnerID _: Int, labels _: [String]) async -> [String]? { nil }
    func fetchRegistrationToken(scope _: String) async -> String? { nil }
    func fetchRemovalToken(scope _: String) async -> String? { nil }
    func deleteRunnerByID(scope _: String, runnerID _: Int) async -> Bool { false }
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
    ///
    /// After stripping, the section should contain exactly:
    ///   ##[group]Build step
    ///   Error occurred at 2026-07-29T03:11:15.4722230Z during build
    ///   ##[endgroup]
    /// The line-start timestamp prefix is removed; the mid-line timestamp is preserved.
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

        // The full stripped content line must be present — this only holds if the
        // line-start prefix was removed AND the mid-line timestamp survived intact.
        #expect(
            result.contains(midLineContent),
            "The full content line (with its mid-line timestamp) must appear after stripping the line-start prefix"
        )
        // No line in the result should begin with a timestamp prefix — guards against
        // the regression where stripping silently fails and the prefix leaks through.
        #expect(
            !result.hasPrefix("2026-07-29T"),
            "The section must not start with a raw timestamp prefix"
        )
        #expect(
            !result.contains("\n2026-07-29T"),
            "No line within the section should begin with a raw timestamp prefix"
        )
    }

    /// Verifies that stripping timestamp prefixes does not corrupt the underlying log content.
    /// The input has timestamp prefixes on every line (as a real log does); the assertion
    /// checks that the content survives the full pipeline (stripAnsi → stripTimestamps →
    /// section slicing) unchanged.
    /// Uses a ##[group]-wrapped payload so parseStepLog takes the section-slicing path
    /// rather than the sections.isEmpty fallback.
    @Test func fetchStepLog_strippingDoesNotCorruptContent() async throws {
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

        #expect(result.contains(cleanLine), "Log content must survive the stripping pipeline unchanged")
        #expect(!result.contains("2026-07-29T"), "Timestamp prefixes must be stripped from the selected section")
    }

    /// Verifies that a blank timestamped line with no trailing space is also stripped.
    /// This exercises the `[^\S\n]*` trailer in timestampRegex.
    /// Note: this log has no `##[group]` markers, so `buildLogSections` returns [] and
    /// `parseStepLog` takes the `sections.isEmpty` fallback path, returning the full
    /// cleaned string. This intentionally tests stripping outside the section-slicing
    /// path; sibling tests that use `##[group]` cover the section path explicitly.
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

    /// Guards the `[^\S\n]*` trailer in timestampRegex: if an ANSI escape sequence
    /// appears immediately after the Z (before the space separator), stripAnsi removes
    /// it first, leaving the Z at end-of-prefix with no trailing space. The widened
    /// trailer must still match and strip the timestamp prefix.
    @Test func fetchStepLog_ansiImmediatelyAfterZ_timestampStillStripped() async throws {
        let transport = MockTransport()
        // ANSI reset (\u{001B}[0m) sits between Z and the space — stripAnsi removes it,
        // leaving `2026-07-29T03:11:15.4722230Z content` which the widened regex must match.
        let rawLog = "2026-07-29T03:11:15.4722230Z\u{001B}[0m content after ansi"
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 8, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("2026-07-29T"), "Timestamp prefix must be stripped even when ANSI code follows Z directly")
        #expect(!result.contains("\u{001B}["), "ANSI escape sequence must be stripped")
        #expect(result.contains("content after ansi"), "Log content must be preserved")
    }

    /// Guards the `(\.\d+)?` optional fractional-seconds group in timestampRegex.
    /// A whole-second RFC 3339 timestamp (no sub-second component) must also be stripped.
    /// This could occur with self-hosted runners or future runner versions that omit
    /// the fractional-seconds field.
    @Test func fetchStepLog_wholeSecondTimestamp_stripped() async throws {
        let transport = MockTransport()
        let rawLog = "2026-07-29T03:11:15Z Some content on a whole-second timestamp"
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 9, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("2026-07-29T"), "Whole-second timestamp prefix must be stripped")
        #expect(
            result.contains("Some content on a whole-second timestamp"),
            "Log content must be preserved after stripping whole-second timestamp"
        )
    }

    /// Guards CRLF normalisation in stripTimestamps: raw log bytes with \r\n line endings
    /// (as may arrive from Windows runners or zip-archive log downloads) must not leave
    /// stray \r characters in the output. Verifies that ##[group] section parsing
    /// still works correctly after normalisation.
    @Test func fetchStepLog_crlfLineEndings_normalisedAndStripped() async throws {
        let transport = MockTransport()
        // Construct a CRLF log with a ##[group] block so buildLogSections exercises
        // the section-slicing path, confirming \r doesn't corrupt the group marker.
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z ##[group]Build step",
            "2026-07-29T03:11:15.5000000Z Building project",
            "2026-07-29T03:11:15.6000000Z ##[endgroup]"
        ].joined(separator: "\r\n")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 10, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("\r"), "No stray \\r characters should survive CRLF normalisation")
        #expect(!result.contains("2026-07-29T"), "Timestamp prefixes must be stripped from CRLF input")
        #expect(result.contains("Building project"), "Log content must be preserved after CRLF normalisation")
    }

    /// Guards the bare-CR normalisation branch in stripTimestamps: raw log bytes with
    /// bare \r line endings (not \r\n) must also be normalised to \n so that no stray
    /// \r characters survive and ##[group] section parsing works correctly.
    /// This complements fetchStepLog_crlfLineEndings_normalisedAndStripped, which covers
    /// the \r\n branch; together they fully exercise the two-pass CR normalisation.
    @Test func fetchStepLog_bareCrLineEndings_normalisedAndStripped() async throws {
        let transport = MockTransport()
        let rawLog = [
            "2026-07-29T03:11:15.4722230Z ##[group]Build step",
            "2026-07-29T03:11:15.5000000Z Building project",
            "2026-07-29T03:11:15.6000000Z ##[endgroup]"
        ].joined(separator: "\r")
        transport.stubRawData = Data(rawLog.utf8)

        let result = try #require(
            await fetchStepLog(jobID: 12, stepNumber: 1, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil for valid log"
        )

        #expect(!result.contains("\r"), "No stray \\r characters should survive bare-CR normalisation")
        #expect(!result.contains("2026-07-29T"), "Timestamp prefixes must be stripped from bare-CR input")
        #expect(result.contains("Building project"), "Log content must be preserved after bare-CR normalisation")
    }

    /// Guards the out-of-range fallback path in parseStepLog: when `stepNumber` exceeds
    /// the number of `##[group]` sections found in the log, parseStepLog returns the full
    /// cleaned log rather than nil or crashing.
    /// This test uses two ##[group] sections and requests stepNumber 99 to trigger the
    /// fallback branch explicitly.
    @Test func fetchStepLog_stepNumberOutOfRange_returnsFullLog() async throws {
        let transport = MockTransport()
        let rawLog = [
            "2026-07-29T03:11:15.0000000Z ##[group]Step one",
            "2026-07-29T03:11:15.1000000Z Step one content",
            "2026-07-29T03:11:15.2000000Z ##[endgroup]",
            "2026-07-29T03:11:15.3000000Z ##[group]Step two",
            "2026-07-29T03:11:15.4000000Z Step two content",
            "2026-07-29T03:11:15.5000000Z ##[endgroup]"
        ].joined(separator: "\n")
        transport.stubRawData = Data(rawLog.utf8)

        // stepNumber 99 is out of range for a 2-section log — parseStepLog falls back
        // to returning the full cleaned log.
        let result = try #require(
            await fetchStepLog(jobID: 11, stepNumber: 99, scope: "runbot-hq/run-bot", transport: transport),
            "fetchStepLog should return non-nil even when stepNumber is out of range"
        )

        // Full log is returned — both sections' content must be present.
        #expect(result.contains("Step one content"), "Fallback must include content from the first section")
        #expect(result.contains("Step two content"), "Fallback must include content from the second section")
        #expect(!result.contains("2026-07-29T"), "Timestamp prefixes must still be stripped in the fallback path")
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
