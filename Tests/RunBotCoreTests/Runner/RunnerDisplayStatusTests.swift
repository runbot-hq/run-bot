// RunnerDisplayStatusTests.swift
// RunBotCoreTests
import Testing
import GitHubClient
@testable import RunBotCore

// MARK: - Runner.displayStatus (via GitHubRunner+AppExtensions)

@Suite("Runner.displayStatus")
struct RunnerDisplayStatusTests {

    private func makeRunner(status: RunnerStatus, busy: Bool = false) -> GitHubRunner {
        GitHubRunner(id: 1, name: "r", status: status, busy: busy)
    }

    @Test func offlineReturnsOffline() {
        #expect(makeRunner(status: .offline).displayStatus(metrics: nil) == "offline")
    }

    @Test func unknownReturnsOffline() {
        #expect(makeRunner(status: .unknown("draining")).displayStatus(metrics: nil) == "offline")
    }

    @Test func onlineIdleNoMetrics() {
        #expect(
            makeRunner(status: .online, busy: false).displayStatus(metrics: nil)
                == "idle (CPU: \u{2014} MEM: \u{2014})")
    }

    @Test func onlineBusyWithMetrics() {
        let m = RunnerMetrics(cpu: 45.0, mem: 12.3)
        #expect(
            makeRunner(status: .online, busy: true).displayStatus(metrics: m)
                == "active (CPU: 45.0% MEM: 12.3%)")
    }

    @Test func busyStatusShowsActiveWithMetrics() {
        let m = RunnerMetrics(cpu: 80.0, mem: 50.0)
        #expect(
            makeRunner(status: .busy, busy: true).displayStatus(metrics: m)
                == "active (CPU: 80.0% MEM: 50.0%)")
    }
}
