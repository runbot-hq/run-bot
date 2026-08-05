// RunnerStatusEnricherTests.swift
// RunBotCoreTests
//
// Tests scope filtering for stopped local runners (#2467).
@testable import RunBotCore
import Foundation
import Testing

// MARK: - Helpers

/// Builds a runner with a GitHub scope so it would normally contribute to enrichment.
private func makeEnrichableRunner(
    name: String,
    isRunning: Bool,
    gitHubUrl: URL = URL(string: "https://github.com/eoncode/runner-bar")!
) -> RunnerModel {
    RunnerModel(
        runnerName: name,
        gitHubUrl: gitHubUrl,
        agentId: nil,
        workFolder: nil,
        installPath: testRunnerInstallPath,
        isRunning: isRunning,
        githubStatus: .online,
        isBusy: false,
        lifecycleWarning: nil
    )
}

// MARK: - Suite

@Suite("RunnerStatusEnricher.buildScopeToRunnerIndices — stopped runner filtering (#2467)")
struct RunnerStatusEnricherTests {
    private let scope = "https://github.com/eoncode/runner-bar"

    @Test("All-stopped runners produce no scopes")
    func allStoppedProducesNoScopes() {
        let runners = [
            makeEnrichableRunner(name: "run-bar-repo-runner-2", isRunning: false),
            makeEnrichableRunner(name: "run-bar-runner-1", isRunning: false)
        ]

        let scopes = RunnerStatusEnricher().buildScopeToRunnerIndices(runners)

        #expect(scopes.isEmpty)
    }

    @Test("All-running runners deduplicate a shared scope")
    func allRunningProducesOneDeduplicatedScope() {
        let runners = [
            makeEnrichableRunner(name: "run-bar-repo-runner-2", isRunning: true),
            makeEnrichableRunner(name: "run-bar-runner-1", isRunning: true)
        ]

        let scopes = RunnerStatusEnricher().buildScopeToRunnerIndices(runners)

        #expect(scopes.count == 1)
        #expect(scopes[scope] == [0, 1])
    }

    @Test("Mixed list includes only the running runner index")
    func mixedListIncludesOnlyRunningIndex() {
        let runners = [
            makeEnrichableRunner(name: "stopped-runner", isRunning: false),
            makeEnrichableRunner(name: "running-runner", isRunning: true)
        ]

        let scopes = RunnerStatusEnricher().buildScopeToRunnerIndices(runners)

        #expect(scopes.count == 1)
        #expect(scopes[scope] == [1])
    }
}
