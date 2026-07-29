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

    func test_fetchStepLog_plainLog_noTimestamps_returnedUnchanged() async {
        let rawLog = "Cleaning up orphan processes\nAll steps succeeded."
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 2, stepNumber: 1, scope: scope, transport: transport)

        XCTAssertEqual(result, rawLog, "A log with no timestamps should be returned unchanged")
    }

    // MARK: ANSI stripping (regression guard)

    func test_fetchStepLog_stripsAnsiEscapeCodes() async {
        let rawLog = "2026-07-29T03:11:15.4722230Z \u{001B}[31mError: build failed\u{001B}[0m"
        transport.stubRawData = Data(rawLog.utf8)

        let result = await fetchStepLog(jobID: 3, stepNumber: 1, scope: scope, transport: transport)

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
        let result = await fetchStepLog(jobID: 4, stepNumber: 1, scope: "runbot-hq", transport: transport)
        XCTAssertNil(result, "fetchStepLog should return nil for org-only scope")
    }

    func test_fetchStepLog_returnsNil_whenTransportReturnsNil() async {
        transport.stubRawData = nil
        let result = await fetchStepLog(jobID: 5, stepNumber: 1, scope: scope, transport: transport)
        XCTAssertNil(result, "fetchStepLog should return nil when transport returns nil")
    }
}
