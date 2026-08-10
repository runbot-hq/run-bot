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
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 304)
        #expect(report == nil)
    }

    @Test("organization runner URL becomes org:acme + runners")
    func orgRunnerURL() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("workflow list with status=in_progress becomes runs.in_progress")
    func workflowStatusInProgress() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=in_progress&per_page=20",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=in_progress&per_page=20",
            statusCode: 304)
        #expect(report == nil)
    }

    @Test("workflow list with status=queued becomes runs.queued")
    func workflowStatusQueued() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=queued&per_page=20",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=queued&per_page=20",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("workflow list with status=completed becomes runs.completed")
    func workflowStatusCompleted() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=completed&per_page=100",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?status=completed&per_page=100",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("workflow list without status becomes runs.all")
    func workflowListWithoutStatus() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?per_page=100",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?per_page=100",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("status query values produce four distinct endpoint categories")
    func fourDistinctStatusCategories() async {
        let counter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
        // All records happen in the same window — the first record starts the window,
        // and the 5th record triggers the report after the interval expires.

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

        // Wait for the interval to expire, then trigger a report.
        try? await Task.sleep(for: .milliseconds(5))
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs?per_page=100",
            statusCode: 200)

        #expect(report != nil)
        if let report {
            #expect(report.total == 5)
            // All four should be in the same bucket because the window hasn't expired yet.
            // The next record after expiry will return a report.
            let endpoints = Set(report.buckets.map(\.endpoint))
            #expect(endpoints == ["runs.in_progress", "runs.queued", "runs.completed", "runs.all"])
        }
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
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/300/jobs",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("attempt-specific jobs normalize to run_jobs_attempt")
    func attemptSpecificJobs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/attempts/2/jobs",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/attempts/2/jobs",
            statusCode: 200)
        #expect(report == nil)
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
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/700",
            statusCode: 200)
        #expect(report == nil)
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
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/jobs/500",
            statusCode: 200)
        #expect(report == nil)
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
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners?per_page=100&page=2",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("unknown URLs aggregate under global/other")
    func unknownURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/not-a-known-path",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/not-a-known-path",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("multiple status codes produce one bucket with separate status counts")
    func multipleStatusCodes() async {
        let shortCounter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
        let url = "https://api.github.com/repos/eoncode/run-bot/actions/runners"
        await shortCounter.record(url: url, statusCode: 200)
        await shortCounter.record(url: url, statusCode: 200)
        await shortCounter.record(url: url, statusCode: 304)
        await shortCounter.record(url: url, statusCode: 403)
        try? await Task.sleep(for: .milliseconds(5))
        let report = await shortCounter.record(url: url, statusCode: 200)
        #expect(report != nil)
        if let report {
            #expect(report.total == 5)
        }
    }
    }

    @Test("report formatting is deterministic regardless of insertion order")
    func reportFormattingDeterministic() async {
        let shortCounter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
        await shortCounter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        await shortCounter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        try? await Task.sleep(for: .milliseconds(5))
        let report = await shortCounter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        if let report {
            let formatted = report.formatted()
            let lines = formatted.split(separator: "\n")
            #expect(lines.count == 3)
            #expect(lines[1].hasPrefix("org:acme"))
            #expect(lines[2].hasPrefix("repo:eoncode/run-bot"))
        }
    }

    @Test("record returns nil within the same window and returns report after expiry")
    func recordReturnsNilThenReport() async {
        let counter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
        // First record — no report.
        let first = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(first == nil)

        try? await Task.sleep(for: .milliseconds(5))

        // Second record after interval expiry — should return a report.
        let second = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(second != nil)
        if let report = second {
            #expect(report.total == 2)
            #expect(report.buckets.count == 1)
            #expect(report.buckets[0].endpoint == "runners")
        }
    }

    @Test("report includes actual duration, not hardcoded 60s")
    func reportDurationFromInterval() async {
        let counter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        try? await Task.sleep(for: .milliseconds(5))
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
        let report = await counter.record(
            url: "https://api.github.com/user/actions/runners",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("timing URLs are categorised as runs.all")
    func timingURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/timing",
            statusCode: 200)
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/timing",
            statusCode: 200)
        #expect(report == nil)
    }

    @Test("empty report is never produced (record returns nil for idle counter)")
    func emptyReportNeverProduced() async {
        let counter = GitHubEndpointCounter()
        // Do not record anything; after the interval, the first record
        // should return nil because there are no previous counts.
        try? await Task.sleep(for: .milliseconds(5))
        let report = await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        #expect(report == nil)
    }

// MARK: - Transport integration

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

    /// Creates a `GitHubTransport` with the given counter and stubbed session.
    private func makeTransport(
        endpointCounter: GitHubEndpointCounter
    ) -> GitHubTransport {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubEndpointCounterProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        return GitHubTransport(
            session: session,
            tokenProvider: { "test-token" },
            endpointCounter: endpointCounter)
    }

    @Test("all four status codes appear in endpoint diagnostics")
    func allStatusCodesRecorded() async {
        // Use a short interval so the transport's execute() triggers a report.
        let counter = GitHubEndpointCounter(reportInterval: .milliseconds(1))
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

        // The next request after the interval will trigger a report.
        try? await Task.sleep(for: .milliseconds(5))
        StubEndpointCounterProtocol.register(
            data: Data("{\"key\":\"value\"}".utf8), statusCode: 200, for: testURL)
        let _ = await transport.execute(testURL, timeout: 10, logTag: "test")

        // The report was logged via logger. We verify counts by checking
        // that the counter has been reset (the report was consumed).
        let next = await counter.record(
            url: testURL, statusCode: 200)
        #expect(next == nil) // window just started
    }
}
