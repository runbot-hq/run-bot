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

// MARK: - ActiveJob convenience init (test-only)
//
// The production ActiveJob initialiser takes a GitHubJob as `raw:`. These
// extensions expose a flat convenience init and shim computed properties that
// match the API the tests were written against, bridging between the two without
// changing any production code.

/// ISO 8601 formatter for converting Date ↔ String inside test helpers.
/// Matches the formatter used by GitHubJob+AppExtensions.
nonisolated(unsafe) private let _testISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

extension ActiveJob {
    /// Flat test-only convenience initialiser. Builds a `GitHubJob` under the
    /// hood and wraps it in an `ActiveJob`.
    init(
        id: Int,
        name: String,
        status: JobStatus,
        htmlUrl: String? = nil,
        conclusion: JobConclusion? = nil,
        isDimmed: Bool = false,
        runnerName: String? = nil,
        scope: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        steps: [GitHubStep] = []
    ) {
        let raw = GitHubJob(
            id: id,
            runID: 0,
            name: name,
            status: status.rawValue,
            conclusion: conclusion?.rawValue,
            htmlUrl: htmlUrl,
            runnerName: runnerName,
            startedAt: startedAt.map { _testISO8601.string(from: $0) },
            completedAt: completedAt.map { _testISO8601.string(from: $0) },
            createdAt: createdAt.map { _testISO8601.string(from: $0) },
            steps: steps
        )
        self.init(
            raw: raw,
            isDimmed: isDimmed,
            scope: scope,
            statusOverride: nil,
            conclusionOverride: nil
        )
    }

    /// Convenience init accepting a raw status string (used by tests that pass
    /// literal strings like `"completed"` or `"in_progress"`).
    init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        isDimmed: Bool = false,
        completedAt: Date? = nil
    ) {
        self.init(
            id: id,
            name: name,
            status: JobStatus(rawString: status),
            conclusion: conclusion.map { JobConclusion(rawString: $0) },
            isDimmed: isDimmed,
            completedAt: completedAt
        )
    }

    // MARK: Shim computed properties
    //
    // These expose the typed API the tests were written against.
    // They forward to the underlying jobStatus / jobConclusion / *Date properties.

    /// Typed effective status (alias for `jobStatus`).
    var status: JobStatus { jobStatus }
    /// Typed effective conclusion (alias for `jobConclusion`).
    var conclusion: JobConclusion? { jobConclusion }
    /// Parsed completion date (alias for `completedDate`).
    var completedAt: Date? { completedDate }
    /// Parsed creation date (alias for `createdDate`).
    var createdAt: Date? { createdDate }
    /// Parsed start date (alias for `startDate`).
    var startedAt: Date? { startDate }
}

// MARK: - JobStep (test-only alias)
//
// Tests were written against a `JobStep` type with an `id:` parameter.
// The production type is `GitHubStep` which uses `number` instead of `id`.
// This typealias + convenience factory let old test code compile unchanged.

typealias JobStep = GitHubStep

extension GitHubStep {
    /// Convenience init used by tests: maps the `id` label to `number`.
    init(id: Int, name: String, status: JobStatus, conclusion: JobConclusion?, number: Int) {
        self.init(
            name: name,
            status: status.rawValue,
            conclusion: conclusion?.rawValue,
            number: number,
            startedAt: nil,
            completedAt: nil
        )
    }
}

// MARK: - GitHubRunner convenience init (test-only)
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
    // GitHubRunner is Codable with no public memberwise init, so we round-trip
    // through JSON to construct a test instance.
    let json = """
    {"id":\(id),"name":\"\(name)\","status\":\"\(status.rawValue)\","busy":\(busy ? "true" : "false"),"labels":[]}
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
