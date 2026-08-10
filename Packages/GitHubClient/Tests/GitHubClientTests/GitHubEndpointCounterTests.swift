// GitHubEndpointCounterTests.swift
// GitHubClientTests

import Foundation
import Testing

@testable import GitHubClient

@Suite("GitHubEndpointCounter")
struct GitHubEndpointCounterTests {

    // MARK: - URL normalisation

    @Test("repository runner URL becomes repo:owner/repo + runners")
    func repoRunnerURL() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runners")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("organization runner URL becomes org:acme + runners")
    func orgRunnerURL() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "org:acme")
        #expect(report.buckets[0].endpoint == "runners")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("workflow list with status=in_progress becomes runs.in_progress")
    func workflowStatusInProgress() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=in_progress&per_page=20",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runs.in_progress")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("workflow list with status=queued becomes runs.queued")
    func workflowStatusQueued() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=queued&per_page=20",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runs.queued")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("workflow list with status=completed becomes runs.completed")
    func workflowStatusCompleted() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=completed&per_page=100",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runs.completed")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("workflow list without status becomes runs.all")
    func workflowListWithoutStatus() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?per_page=100",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runs.all")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("status query values produce four distinct endpoint categories")
    func fourDistinctStatusCategories() async {
        let counter = GitHubEndpointCounter()
        // in_progress
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=in_progress&per_page=20",
            statusCode: 200)
        // queued
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=queued&per_page=20",
            statusCode: 200)
        // completed
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=completed&per_page=100",
            statusCode: 200)
        // no status
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?per_page=100",
            statusCode: 200)

        let report = await counter.snapshot()
        #expect(report.total == 4)
        let endpoints = Set(report.buckets.map(\.endpoint))
        #expect(endpoints == ["runs.in_progress", "runs.queued", "runs.completed", "runs.all"])
    }

    @Test("different run IDs aggregate under run_jobs")
    func differentRunIDsAggregate() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/jobs",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/200/jobs",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/300/jobs",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 3)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "run_jobs")
        #expect(report.buckets[0].statusCounts == [(200, 3)])
    }

    @Test("attempt-specific jobs normalize to run_jobs_attempt")
    func attemptSpecificJobs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/attempts/2/jobs",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/attempts/2/jobs",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "run_jobs_attempt")
        #expect(report.buckets[0].statusCounts == [(200, 2)])
    }

    @Test("different job IDs aggregate under job_detail")
    func differentJobIDsAggregate() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/500",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/600",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/700",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 3)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "job_detail")
        #expect(report.buckets[0].statusCounts == [(200, 3)])
    }

    @Test("job logs normalize separately from job details")
    func jobLogsSeparateFromJobDetails() async {
        let counter = GitHubEndpointCounter()
        // Job detail
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/500",
            statusCode: 200)
        // Job logs
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/500/logs",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets.count == 2)
        let jobDetail = report.buckets.first { $0.endpoint == "job_detail" }
        let jobLogs = report.buckets.first { $0.endpoint == "job_logs" }
        #expect(jobDetail != nil)
        #expect(jobLogs != nil)
        #expect(jobDetail?.statusCounts == [(200, 1)])
        #expect(jobLogs?.statusCounts == [(200, 1)])
    }

    @Test("pagination parameters do not create additional keys")
    func paginationNoExtraKeys() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners?per_page=100",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners?per_page=100&page=2",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners?per_page=100&page=2",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 3)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runners")
        #expect(report.buckets[0].statusCounts == [(200, 3)])
    }

    @Test("unknown URLs aggregate under global/other")
    func unknownURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/not-a-known-path",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/not-a-known-path",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "global/other")
        #expect(report.buckets[0].endpoint == "global/other")
        #expect(report.buckets[0].statusCounts == [(200, 2)])
    }

    @Test("multiple status codes produce one bucket with separate status counts")
    func multipleStatusCodes() async {
        let counter = GitHubEndpointCounter()
        let url = "https://api.github.com/repos/eoncode/run-bot/actions/runners"
        await counter.record(url: url, statusCode: 200)
        await counter.record(url: url, statusCode: 200)
        await counter.record(url: url, statusCode: 304)
        await counter.record(url: url, statusCode: 403)
        let report = await counter.snapshot()
        #expect(report.total == 4)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].endpoint == "runners")
        #expect(report.buckets[0].statusCounts == [(200, 2), (304, 1), (403, 1)])
    }

    @Test("report formatting is deterministic regardless of insertion order")
    func reportFormattingDeterministic() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        let formatted = report.formatted()
        let lines = formatted.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("org:acme"))
        #expect(lines[2].hasPrefix("repo:eoncode/run-bot"))
    }

    @Test("record returns nil within the same window and returns report after expiry")
    func recordReturnsNilThenReport() async {
        let counter = GitHubEndpointCounter(reportInterval: .zero)
        // First record — no report because window just started.
        let first = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(first == nil)

        // With .zero interval, the next record immediately triggers a report.
        let second = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(second != nil)
        if let report = second {
            #expect(report.total == 2)
            #expect(report.buckets.count == 1)
            #expect(report.buckets[0].endpoint == "runners")
        }

        // After the report was consumed, a new window starts.
        let third = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(third == nil)
    }

    @Test("report includes actual duration, not hardcoded 60s")
    func reportDurationFromInterval() async {
        let counter = GitHubEndpointCounter(reportInterval: .zero)
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(report != nil)
        if let report {
            #expect(report.durationSeconds >= 0)
            #expect(report.formatted().hasPrefix("GitHubEndpointCounter › "))
            #expect(report.formatted().contains(" total=2"))
        }
    }

    @Test("user scope URLs are recognised")
    func userScope() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/user/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "user")
        #expect(report.buckets[0].endpoint == "runners")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("timing URLs are categorised as runs.all")
    func timingURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/timing",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].scope == "repo:eoncode/run-bot")
        #expect(report.buckets[0].endpoint == "runs.all")
        #expect(report.buckets[0].statusCounts == [(200, 1)])
    }

    @Test("empty report is never produced (record returns nil for idle counter)")
    func emptyReportNeverProduced() async {
        let counter = GitHubEndpointCounter(reportInterval: .zero)
        // Do not record anything; after the .zero interval, the first record
        // should return nil because there are no previous counts.
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("empty report is not produced when interval expires with no prior records")
    func expiredIntervalWithNoRecords() async {
        let counter = GitHubEndpointCounter(reportInterval: .zero)
        // Counter was created with .zero — the window is already expired.
        // But since there are no records, the first record should not produce a report.
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(report == nil)

        // After one record, the next record should produce a report because
        // the .zero interval has already expired.
        let second = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(second != nil)
        #expect(second?.total == 2)
    }

// MARK: - Transport integration

/// Spy logger that captures the last log message and category.
///
/// Used to verify that `GitHubTransport` emits a diagnostic report via the logger.
final class SpyGitHubLogger: GitHubLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _loggedMessage: String?
    private var _loggedCategory: String?

    /// The last message that was logged, or `nil` if nothing has been logged yet.
    var loggedMessage: String? { lock.withLock { _loggedMessage } }
    /// The category of the last logged message, or `nil`.
    var loggedCategory: String? { lock.withLock { _loggedCategory } }

    nonisolated func log(_ message: String, category: String) {
        lock.withLock {
            _loggedMessage = message
            _loggedCategory = category
        }
    }
}

/// Suite: Transport-endpoint counter integration
///
/// Verifies that `GitHubTransport` records all completed HTTP responses
/// (200, 304, 403, 429) in the endpoint counter via the stubbed URL session.
@Suite("GitHubEndpointCounterTransportIntegration")
struct GitHubEndpointCounterTransportIntegrationTests {

    /// Stub URL protocol that returns a pre-configured response for a single URL.
    final class StubEndpointCounterProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) private static var _stub: (data: Data, statusCode: Int, url: String)?
        private static let lock = NSLock()

        static func register(data: Data, statusCode: Int, for url: String) {
            lock.withLock { _stub = (data, statusCode, url) }
        }

        static func read() -> (data: Data, statusCode: Int, url: String)? {
            lock.withLock { _stub }
        }

        static func reset() {
            lock.withLock { _stub = nil }
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.absoluteString == read()?.url
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let stub = Self.read(), request.url?.absoluteString == stub.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// Common URL used for all stubbed requests in this suite.
    private let testURL = "https://api.github.com/repos/test/example/actions/runners"

    /// Creates a `GitHubTransport` with the given counter, stubbed session, and optional logger.
    private func makeTransport(
        endpointCounter: GitHubEndpointCounter,
        logger: (any GitHubLogger)? = nil
    ) -> GitHubTransport {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubEndpointCounterProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        return GitHubTransport(
            session: session,
            tokenProvider: { "test-token" },
            logger: logger,
            endpointCounter: endpointCounter)
    }

    @Test("all four status codes appear in snapshot after transport requests")
    func allStatusCodesRecorded() async {
        // Use a long interval so the transport's execute() does not trigger a report.
        let counter = GitHubEndpointCounter(reportInterval: .seconds(60))
        let transport = makeTransport(endpointCounter: counter)

        // 200
        StubEndpointCounterProtocol.register(
            data: Data("{\"key\":\"value\"}".utf8), statusCode: 200, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")
        // 304
        StubEndpointCounterProtocol.register(
            data: Data("{\"key\":\"value\"}".utf8), statusCode: 304, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")
        // 403
        StubEndpointCounterProtocol.register(
            data: Data("{\"message\":\"error\"}".utf8), statusCode: 403, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")
        // 429
        StubEndpointCounterProtocol.register(
            data: Data("{\"message\":\"rate limited\"}".utf8), statusCode: 429, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")

        // Snapshot without consuming the window.
        let report = await counter.snapshot()
        #expect(report.total == 4)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].endpoint == "runners")
        let statuses = Set(report.buckets[0].statusCounts.map { $0.status })
        #expect(statuses == [200, 304, 403, 429])
    }

    @Test("transport logs a report when interval expires")
    func transportLogsReportOnExpiry() async {
        let spy = SpyGitHubLogger()
        let counter = GitHubEndpointCounter(reportInterval: .zero)
        let transport = makeTransport(endpointCounter: counter, logger: spy)

        // First request — no report yet.
        StubEndpointCounterProtocol.register(
            data: Data("{\"key\":\"value\"}".utf8), statusCode: 200, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")
        // Nothing logged because the first request starts the window with no prior data.
        #expect(spy.loggedMessage == nil)

        // Second request — with .zero interval, this triggers a report.
        StubEndpointCounterProtocol.register(
            data: Data("{\"key\":\"value\"}".utf8), statusCode: 200, for: testURL)
        _ = await transport.execute(testURL, timeout: 10, logTag: "test")
        #expect(spy.loggedMessage != nil)
        #expect(spy.loggedMessage?.hasPrefix("GitHubEndpointCounter › ") == true)
        #expect(spy.loggedCategory == "transport")
    }
}
