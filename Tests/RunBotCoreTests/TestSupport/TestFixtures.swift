// TestFixtures.swift
// RunBotCoreTests
// Shared test fixtures — extracted per #1446.
import Foundation
import GitHubClient
import RunBotCore

// MARK: - Constants

/// Stable install path used across test fixtures to avoid repeating a hardcoded URI literal.
internal let testRunnerInstallPath = "/tmp/runner" // NOSONAR — test-only fixture path

// MARK: - Factories

/// Creates a `RunnerModel` with sensible defaults for display-status and status-colour tests.
///
/// Extracted from `RunnerModelDisplayStatusTests` and `RunnerModelStatusColorTests`
/// where it was defined identically as a private helper in each suite (#1446).
func makeRunnerModel(
    isRunning: Bool,
    isBusy: Bool = false,
    githubStatus: RunnerStatus = .online,
    lifecycleWarning: String? = nil,
    workFolder: String? = nil
) -> RunnerModel {
    RunnerModel(
        runnerName: "test-runner",
        gitHubUrl: nil,
        agentId: nil,
        workFolder: workFolder,
        installPath: testRunnerInstallPath,
        isRunning: isRunning,
        githubStatus: githubStatus,
        isBusy: isBusy,
        lifecycleWarning: lifecycleWarning
    )
}

// MARK: - GitHubRunner convenience factory (test-only)
//
// Tests that previously used `Runner(id:name:status:busy:metrics:)` now need to
// use `GitHubRunner` + the `displayStatus(metrics:)` extension from RunBotCore.
// This factory function bridges the gap.

func makeGitHubRunner(
    id: Int = 1,
    name: String = "r",
    status: RunnerStatus,
    busy: Bool = false
) -> GitHubRunner {
    // GitHubRunner.labels is [GitHubRunnerLabel] (not [String]) and has no public
    // memberwise init, so we round-trip through JSON to construct a test instance.
    let json = """
    {"id":\(id),"name":\"\(name)\","status":\"\(status.rawValue)\","busy":\(busy ? "true" : "false"),"labels":[]}
    """
    return try! JSONDecoder().decode(GitHubRunner.self, from: Data(json.utf8))
}

// MARK: - WorkflowActionGroup

extension WorkflowActionGroup {
    /// Returns a minimal `WorkflowActionGroup` suitable for `FailureHookRunnerUseCaseTests`.
    ///
    /// - Parameters:
    ///   - conclusion: The conclusion of the single synthetic run. Defaults to `.failure`.
    ///   - branch: The `headBranch` of the group. Defaults to `"main"`.
    ///   - workflowName: The `name` of the synthetic `WorkflowRunRef`. Defaults to `"CI"`.
    ///     Use this to inject special characters (e.g. single quotes) for shell-escaping tests.
    static func fixture(
        conclusion: JobConclusion? = .failure,
        branch: String? = "main",
        workflowName: String = "CI"
    ) -> WorkflowActionGroup {
        let run = WorkflowRunRef(
            id: 999,
            name: workflowName,
            status: .completed,
            conclusion: conclusion,
            htmlUrl: "https://github.com/owner/repo/actions/runs/999"
        )
        return WorkflowActionGroup(
            headSha: "abc123def456abc123def456abc123def456abc1",
            label: "abc123",
            title: "CI",
            headBranch: branch,
            repo: "owner/repo",
            runs: [run],
            jobs: [],
            firstJobStartedAt: nil,
            lastJobCompletedAt: nil,
            createdAt: nil,
            isDimmed: false
        )
    }
}
