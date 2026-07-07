// GitHubRunnerDisplayStatusTests.swift
// RunBotCoreTests
//
// Tests GitHubRunner.displayStatus(metrics:) — renamed from RunnerDisplayStatusTests
// to distinguish it from RunnerModelDisplayStatusTests (which tests RunnerModel.displayStatus).
import GitHubClient
@testable import RunBotCore
import Testing

// MARK: - GitHubRunner.displayStatus (via GitHubRunner+AppExtensions)

@Suite("GitHubRunner.displayStatus")
struct GitHubRunnerDisplayStatusTests {

  private func makeRunner(status: RunnerStatus, busy: Bool = false) -> GitHubRunner {
    GitHubRunner(id: 1, name: "r", status: status, busy: busy)
  }

  /// Verifies that a runner with `.offline` status returns "offline" regardless of metrics.
  @Test func offlineReturnsOffline() {
    #expect(makeRunner(status: .offline).displayStatus(metrics: nil) == "offline")
  }

  /// Verifies that a runner with an `.unknown` status returns "offline", treating unrecognised
  /// statuses as offline to avoid surfacing internal agent state to the UI.
  @Test func unknownReturnsOffline() {
    #expect(makeRunner(status: .unknown("draining")).displayStatus(metrics: nil) == "offline")
  }

  /// #1983 Step 3 — .unknown + busy: true must still return "offline" regardless of busy flag.
  @Test func unknownBusyTrueReturnsOffline() {
    #expect(
      makeRunner(status: .unknown("draining"), busy: true).displayStatus(metrics: nil)
        == "offline")
  }

  /// Verifies that an online, idle runner with no metrics returns the dash-placeholder string
  /// "idle (CPU: — MEM: —)", confirming the nil-metrics fallback path for the idle state.
  @Test func onlineIdleNoMetrics() {
    #expect(
      makeRunner(status: .online, busy: false).displayStatus(metrics: nil)
        == "idle (CPU: \u{2014} MEM: \u{2014})")
  }

  /// Verifies that an online, busy runner with live metrics returns a formatted "active" string
  /// containing the CPU and memory percentages rounded to one decimal place.
  @Test func onlineBusyWithMetrics() {
    let m = RunnerMetrics(cpu: 45.0, mem: 12.3)
    #expect(
      makeRunner(status: .online, busy: true).displayStatus(metrics: m)
        == "active (CPU: 45.0% MEM: 12.3%)")
  }

  /// #1983 Step 3 — online + busy: true + metrics: nil must fall back to the dash placeholder string.
  @Test func onlineBusyNilMetricsFallsBackToDashes() {
    #expect(
      makeRunner(status: .online, busy: true).displayStatus(metrics: nil)
        == "active (CPU: \u{2014} MEM: \u{2014})")
  }

  /// Verifies that a runner with `.busy` status and live metrics returns a formatted "active" string,
  /// confirming the `.busy` case maps to the active display path identically to `.online` + busy.
  @Test func busyStatusShowsActiveWithMetrics() {
    let m = RunnerMetrics(cpu: 80.0, mem: 50.0)
    #expect(
      makeRunner(status: .busy, busy: true).displayStatus(metrics: m)
        == "active (CPU: 80.0% MEM: 50.0%)")
  }
}
