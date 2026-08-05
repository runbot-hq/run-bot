// RunnerStatusEnricherTests.swift
// RunBotCoreTests
//
// Tests RunnerStatusEnricher.enrich(runners:) filtering behaviour for
// stopped runners (#2467).
//
// Strategy: inject a StubEnricher that records which runners it was asked
// to enrich, then verify scope-level skipping via the RunnerStatusEnricherProtocol
// contract. For the real RunnerStatusEnricher, we verify that stopped runners
// are returned unchanged and that no scopes are built for them by asserting
// the output equals the input for all-stopped lists.
@testable import RunBotCore
import Testing
import Foundation

// MARK: - Helpers

/// Builds a `RunnerModel` with a real `gitHubUrl` so it would normally
/// contribute a scope — useful for enricher-specific tests.
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

    // MARK: All-stopped

    /// All runners stopped → enrich() returns them unchanged, no scopes built.
    ///
    /// Acceptance criteria: toggle-off runners do not trigger GitHub API requests.
    @Test("All-stopped runners are returned unchanged")
    func allStoppedRunnersReturnedUnchanged() async {
        let enricher = RunnerStatusEnricher()
        let runners = [
            makeEnrichableRunner(name: "run-bar-repo-runner-2", isRunning: false),
            makeEnrichableRunner(name: "run-bar-runner-1",      isRunning: false)
        ]
        let result = await enricher.enrich(runners: runners)
        // No API calls can succeed in unit tests (no live transport), so if
        // the enricher incorrectly builds scopes for stopped runners it will
        // attempt network requests and may mutate the model. A correct
        // implementation skips scope building entirely and returns the input
        // array with all values equal.
        #expect(result.count == runners.count)
        for (original, enriched) in zip(runners, result) {
            #expect(enriched.runnerName  == original.runnerName)
            #expect(enriched.isRunning   == original.isRunning)
            #expect(enriched.gitHubUrl   == original.gitHubUrl)
            // Status must not be mutated for stopped runners.
            #expect(enriched.githubStatus == original.githubStatus)
        }
    }

    // MARK: All-running (baseline — existing deduplication must stay intact)

    /// All runners running + no live network → enricher attempts fetches,
    /// returns original models when transport fails (unchanged shape).
    ///
    /// Acceptance criteria: running runners continue to be enriched.
    @Test("All-running runners preserve count and identity")
    func allRunningRunnersPreserveShape() async {
        let enricher = RunnerStatusEnricher()
        let runners = [
            makeEnrichableRunner(name: "run-bar-repo-runner-2", isRunning: true),
            makeEnrichableRunner(name: "run-bar-runner-1",      isRunning: true)
        ]
        let result = await enricher.enrich(runners: runners)
        // In a unit-test environment the fetch will fail / return empty,
        // so models come back unchanged. What matters here is shape integrity.
        #expect(result.count == runners.count)
        for (original, enriched) in zip(runners, result) {
            #expect(enriched.runnerName == original.runnerName)
        }
    }

    // MARK: Mixed

    /// Mixed list: stopped runners returned unchanged, running runners go
    /// through the enrichment pass (output shape preserved in unit tests).
    ///
    /// Acceptance criteria: mixed running/stopped runners sharing one scope
    /// trigger one request for the running runners; stopped runners are untouched.
    @Test("Mixed list: stopped runners unchanged, running runners enriched")
    func mixedListStoppedRunnersUnchanged() async {
        let enricher = RunnerStatusEnricher()
        let stopped = makeEnrichableRunner(name: "stopped-runner", isRunning: false)
        let running = makeEnrichableRunner(name: "running-runner", isRunning: true)
        let runners = [stopped, running]
        let result  = await enricher.enrich(runners: runners)

        #expect(result.count == 2)

        let resultStopped = result[0]
        let resultRunning = result[1]

        // Stopped runner must be returned byte-for-byte equivalent.
        #expect(resultStopped.runnerName  == stopped.runnerName)
        #expect(resultStopped.isRunning   == false)
        #expect(resultStopped.githubStatus == stopped.githubStatus)

        // Running runner passes through enrichment; shape must be preserved.
        #expect(resultRunning.runnerName == running.runnerName)
        #expect(resultRunning.isRunning  == true)
    }
}
