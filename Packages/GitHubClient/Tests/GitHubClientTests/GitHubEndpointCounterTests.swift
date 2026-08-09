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
    }

    @Test("organization runner URL becomes org:acme + runners")
    func orgRunnerURL() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/orgs/acme/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].scope == "org:acme")
        #expect(report.buckets[0].endpoint == "runners")
    }

    @Test("each workflow status query receives the correct category")
    func workflowStatusQuery() async {
        let counter = GitHubEndpointCounter()
        // runs/in_progress
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/status",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].endpoint == "runs.all")
    }

    @Test("missing workflow status becomes runs.all")
    func missingWorkflowStatus() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].endpoint == "runs.all")
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
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].endpoint == "run_jobs")
        #expect(report.buckets[0].statusCounts[0].count == 2)
    }

    @Test("attempt-specific jobs normalize to run_jobs_attempt")
    func attemptSpecificJobs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/100/attempts/2/jobs",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].endpoint == "run_jobs_attempt")
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
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets[0].endpoint == "job_detail")
        #expect(report.buckets[0].statusCounts[0].count == 2)
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
        let report = await counter.snapshot()
        #expect(report.total == 2)
        #expect(report.buckets.count == 1)
        #expect(report.buckets[0].endpoint == "runners")
    }

    @Test("unknown URLs aggregate under global/other")
    func unknownURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/not-a-known-path",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].scope == "global/other")
        #expect(report.buckets[0].endpoint == "global/other")
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
        let bucket = report.buckets[0]
        #expect(bucket.statusCounts.count == 3)
        let status200 = bucket.statusCounts.first { $0.status == 200 }
        let status304 = bucket.statusCounts.first { $0.status == 304 }
        let status403 = bucket.statusCounts.first { $0.status == 403 }
        #expect(status200?.count == 2)
        #expect(status304?.count == 1)
        #expect(status403?.count == 1)
    }

    @Test("report formatting is deterministic regardless of insertion order")
    func reportFormattingDeterministic() async {
        let counter = GitHubEndpointCounter()
        // Insert in reverse-alphabetical scope order.
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
        // org:acme should come before repo:eoncode/run-bot (alphabetically).
        #expect(lines[1].hasPrefix("org:acme"))
        #expect(lines[2].hasPrefix("repo:eoncode/run-bot"))
    }

    @Test("returning a report resets the current window")
    func reportResetsCounters() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        let report = await counter.report()
        #expect(report.total == 1)
        // After report(), counters should be reset.
        let snapshot = await counter.snapshot()
        #expect(snapshot.total == 0)
    }

    @Test("snapshot() does not reset counters")
    func snapshotDoesNotReset() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runners",
            statusCode: 200)
        let snap1 = await counter.snapshot()
        #expect(snap1.total == 1)
        // snapshot() should not reset.
        let snap2 = await counter.snapshot()
        #expect(snap2.total == 1)
    }

    @Test("empty report produces no output")
    func emptyReport() async {
        let counter = GitHubEndpointCounter()
        let report = await counter.report()
        #expect(report.total == 0)
        #expect(report.buckets.isEmpty)
        let formatted = report.formatted()
        #expect(formatted == "GitHubEndpointCounter › 60s total=0")
    }

    @Test("user scope URLs are recognised")
    func userScope() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/user/actions/runners",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.total == 1)
        #expect(report.buckets[0].scope == "user")
        #expect(report.buckets[0].endpoint == "runners")
    }

    @Test("timing URLs are categorised as runs.all")
    func timingURLs() async {
        let counter = GitHubEndpointCounter()
        await counter.record(
            url: "https://api.github.com/repos/eoncode/run-bot/actions/runs/12345/timing",
            statusCode: 200)
        let report = await counter.snapshot()
        #expect(report.buckets[0].endpoint == "runs.all")
    }
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
        nonisolated(unsafe) private static var stub: (data: Data, statusCode: Int, url: String)?

        static func register(data: Data, statusCode: Int, for url: String) {
            stub = (data, statusCode, url)
        }

        static func reset() {
            stub = nil
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.absoluteString == stub?.url
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let stub = Self.stub, request.url?.absoluteString == stub.url else {
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
        let counter = GitHubEndpointCounter()
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

        let report = await counter.snapshot()
        #expect(report.total == 4)
        #expect(report.buckets.count == 1)
        let bucket = report.buckets[0]
        #expect(bucket.scope == "repo:test/example")
        #expect(bucket.endpoint == "runners")
        // Should have 200, 304, 403, 429 — four distinct status codes.
        #expect(bucket.statusCounts.count == 4)
        let statuses = bucket.statusCounts.map(\.status).sorted()
        #expect(statuses == [200, 304, 403, 429])
    }
}
