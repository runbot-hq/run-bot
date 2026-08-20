// OrgRunnerMetricsResolutionTests.swift
// RunBotCoreTests
//
// Regression tests for #1209 / #1192: org-scoped runners must receive CPU/MEM
// metrics even when the local .runner JSON AgentId differs from the GitHub API id.
import Foundation
import RunBotCore
import Testing

// MARK: - OrgRunnerMetricsResolutionTests

/// Tests that verify `RunnerModel.apiId` is preserved through `copying(...)` and
/// can be used to distinguish the GitHub REST API runner id from the local agentId.
///
/// The full `byApiId` lookup lives in `RunnerStore` (a `@MainActor` type in the
/// app target), which cannot be imported from a core-only unit-test target.
/// These tests therefore cover the data-model layer: that `apiId` round-trips
/// correctly and that a `RunnerModel` with mismatched `agentId` / `apiId` values
/// behaves as expected.
///
/// Equatable tests (equalityWithMatchingApiId / inequalityWhenApiIdDiffers) were
/// removed in #1500 — RunnerModel has compiler-synthesised Equatable; testing the
/// compiler adds noise with no regression value, consistent with the policy in #1450.
@Suite("OrgRunnerMetricsResolution")
struct OrgRunnerMetricsResolutionTests {

  // MARK: - Helpers

  private func makeOrgRunner(
    agentId: Int?,
    apiId: Int?,
    installPath: String? = "/tmp/org-runner",  // NOSONAR — test-only fixture path
    metrics: RunnerMetrics? = nil
  ) -> RunnerModel {
    RunnerModel(
      runnerName: "org-runner-1",
      gitHubUrl: URL(string: "https://github.com/myorg"),
      agentId: agentId,
      apiId: apiId,
      workFolder: nil,
      installPath: installPath,
      isRunning: true,
      metrics: metrics
    )
  }

  // MARK: - copying() round-trips

  /// `copying(...)` must preserve `apiId` when no apiId-related field is changed.
  @Test func copyingPreservesApiId() {
    let original = makeOrgRunner(agentId: 100, apiId: 999)
    let copy = original.copying(isRunning: false)
    #expect(copy.apiId == 999)
    #expect(copy.agentId == 100)
  }

  /// `copying(metrics:)` must preserve both `agentId` and `apiId`.
  @Test func copyingWithMetricsPreservesApiId() {
    let original = makeOrgRunner(agentId: 100, apiId: 999)
    let metrics = RunnerMetrics(cpu: 55.0, mem: 30.0)
    let copy = original.copying(metrics: .some(metrics))
    #expect(copy.apiId == 999)
    #expect(copy.agentId == 100)
    #expect(copy.metrics?.cpu == 55.0)
  }

  // MARK: - ID mismatch scenario (org runner)

  /// Simulates the org-runner mismatch: agentId (from .runner JSON, e.g. 100) differs from
  /// apiId (from GitHub REST API, e.g. 5001). The model must hold both simultaneously so the
  /// caller can build both a `byId` (keyed by agentId) and a `byApiId` (keyed by apiId) lookup map.
  @Test func agentIdAndApiIdCanDifferForOrgRunners() {
    let runner = makeOrgRunner(agentId: 100, apiId: 5001)
    #expect(runner.agentId != runner.apiId)
  }

  /// A runner whose `apiId` matches the GitHub API runner id (5001) must be
  /// identifiable by that id even when `agentId` (100) does not match.
  /// This is the `byApiId` lookup path used when metrics arrive keyed by GitHub's runner id.
  @Test func apiIdMatchesGitHubApiRunnerIdForLookup() {
    let runner = makeOrgRunner(agentId: 100, apiId: 5001)
    let byApiId: [Int: String] = runner.apiId.map { [$0: runner.installPath!] } ?? [:]
    #expect(byApiId[5001] != nil)
    #expect(byApiId[100] == nil)
  }

}
