// RunnerStatusEnricherTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

/// Scope-filtering contract for ``RunnerStatusEnricher.buildScopeToRunnerIndices`` (#2467):
/// stopped runners must contribute no enrichment scopes, running runners deduplicate
/// their shared scope, and mixed lists keep only running indices.
@Suite("RunnerStatusEnricher filtering")
struct RunnerStatusEnricherTests {

  @Test
  func scopeFilteringContract() throws {
    let url = try #require(URL(string: "https://github.com/eoncode/runner-bar"))

    /// Builds a runner with a GitHub scope so it would normally contribute to enrichment.
    func runner(_ name: String, running: Bool) -> RunnerModel {
      RunnerModel(
        runnerName: name,
        gitHubUrl: url,
        agentId: nil,
        workFolder: nil,
        installPath: testRunnerInstallPath,
        isRunning: running,
        githubStatus: .online,
        isBusy: false,
        lifecycleWarning: nil
      )
    }

    struct Case {
      let label: String
      let runners: [RunnerModel]
      let expected: [String: [Int]]
    }

    let scope = url.absoluteString
    let cases: [Case] = [
      Case(label: "all stopped",
           runners: [
             runner("stopped-a", running: false),
             runner("stopped-b", running: false),
           ],
           expected: [:]),
      // Two runners on one shared scope collapse into one deduplicated entry.
      Case(label: "shared running scope",
           runners: [
             runner("running-a", running: true),
             runner("running-b", running: true),
           ],
           expected: [scope: [0, 1]]),
      // Only the running index survives.
      Case(label: "mixed",
           runners: [
             runner("stopped", running: false),
             runner("running", running: true),
           ],
           expected: [scope: [1]]),
    ]

    for testCase in cases {
      let result = RunnerStatusEnricher().buildScopeToRunnerIndices(testCase.runners)

      #expect(result == testCase.expected, "\(testCase.label)")
    }
  }
}
