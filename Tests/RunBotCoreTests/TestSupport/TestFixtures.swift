// TestFixtures.swift
// RunBotCoreTests
// Shared test fixtures — extracted per #1446.
import Foundation
import GitHubClient
import RunBotCore

// MARK: - Constants

/// Stable install path used across test fixtures to avoid repeating a hardcoded URI literal.
internal let testRunnerInstallPath = "/tmp/runner" // NOSONAR — test-only fixture path

// MARK: - ZIP log fixture (issue #2369)
//
// Two-file ZIP mirroring the exact structure of the failing job from #2358:
//   release/2_Checkout.txt        — timestamp prefix + ANSI colour codes
//   release/7_Complete job.txt    — synthetic step, no ##[group] markers
//
// Generation (run once; commit the output as fixtureZipBase64 below):
//   mkdir -p /tmp/release
//   printf '2026-07-31T04:34:20.0000000Z \033[32mCheckout output\033[0m\n' \
//     > "/tmp/release/2_Checkout.txt"
//   printf '2026-07-31T04:34:23.0000000Z Cleaning up orphan processes\n' \
//     > "/tmp/release/7_Complete job.txt"
//   printf '2026-07-31T04:34:23.0000001Z ##[warning]Node.js 20 is deprecated.\n' \
//     >> "/tmp/release/7_Complete job.txt"
//   cd /tmp && zip -r logs.zip release/
//   base64 logs.zip | pbcopy

/// Base64-encoded ZIP of the two-file test fixture.
/// Shared by `UnzipLogsTests` and `FetchStepLogTests` — update here to regenerate everywhere.
internal let fixtureZipBase64 =
    "UEsDBBQAAAAIACp7/1zH8jSbMgAAADYAAAAWAAAAcmVsZWFzZS8yX0NoZWNrb3V0LnR4dDMyMD" +
    "LTNTDXNTYMMTCxMjaxMjLQM4CAKAXpaGOjXOeM1OTs/NISBSAuKC2RjjbI5QIAUEsDBBQAAAAI" +
    "ACp7/1x94DpHeAAAAKQAAAAaAAAAcmVsZWFzZS83X0NvbXBsZXRlIGpvYi50eHR1zbEKgzAURuH" +
    "dp/jB2RATacG1eycnS4dgbjUl5IbciK9fpEOnnv3jGG0unb52tp/0MNphNFbpbzNukVwKacWewS" +
    "VvLiEXXkiEpDF/ZT+jbR+HK6d93tmTeguMRhB4yoUWV8krTBvhxTHycT7cUgMnQXVlpYofaz5Q" +
    "SwECFAMUAAAACAAqe/9cx/I0mzIAAAA2AAAAFgAAAAAAAAAAAAAAgAEAAAAAcmVsZWFzZS8yX0No" +
    "ZWNrb3V0LnR4dFBLAQIUAxQAAAAIACp7/1x94DpHeAAAAKQAAAAaAAAAAAAAAAAAAACAAWYAAABy" +
    "ZWxlYXNlLzdfQ29tcGxldGUgam9iLnR4dFBLBQYAAAAAAgACAIwAAAAWAQAAAAA="

/// Decoded bytes of the fixture ZIP. Force-unwrap is intentional: a decode failure
/// means the committed constant is corrupt, which must be caught immediately.
/// Declared as `let` so the base64 decode runs once per process, not once per test access.
internal let fixtureZip: Data =
    Data(base64Encoded: fixtureZipBase64, options: .ignoreUnknownCharacters)!

// MARK: - Subprocess availability probe

/// `true` when the `/usr/bin/unzip` binary is present on disk.
///
/// Evaluated once at process start — the binary is either present or absent for
/// the lifetime of a test run. Declared `let` to match `fixtureZip` and avoid
/// repeated `FileManager` calls in `withKnownIssue(when:)` closures.
/// Tests additionally gate on `files.isEmpty` (or `!isSlice`) at runtime to catch
/// the sandboxed-spawn case where the binary exists but `Process.run()` is blocked.
internal let unzipBinaryExists: Bool = FileManager.default.fileExists(atPath: "/usr/bin/unzip")

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
    busy: Bool = false,
    status: RunnerStatus
) -> GitHubRunner {
    // GitHubRunner.labels is [GitHubRunnerLabel] (not [String]) and has no public
    // memberwise init, so we round-trip through JSON to construct a test instance.
    let json = """
    {"id":\(id),"name":"\(name)","status":"\(status.rawValue)","busy":\(busy ? "true" : "false"),"labels":[]}
    """
    guard let decoded = try? JSONDecoder().decode(GitHubRunner.self, from: Data(json.utf8)) else {
        fatalError("GitHubRunner fixture JSON failed to decode: \(json)")
    }
    return decoded
}

// MARK: - WorkflowActionGroup

extension WorkflowActionGroup {
    /// Returns a workflow group for timestamp and duration tests.
    ///
    /// - Parameters:
    ///   - status: Status assigned to the synthetic workflow run.
    ///   - conclusion: Conclusion assigned to the synthetic workflow run.
    ///   - jobs: Jobs included in the group.
    ///   - firstJobStartedAt: Optional stored aggregate start date.
    ///   - lastJobCompletedAt: Optional stored aggregate completion date.
    static func makeTestGroup(
        status: JobStatus = .completed,
        conclusion: JobConclusion? = .success,
        jobs: [ActiveJob] = [],
        firstJobStartedAt: Date? = nil,
        lastJobCompletedAt: Date? = nil
    ) -> WorkflowActionGroup {
        let run = WorkflowRunRef(
            id: 1,
            name: "CI",
            status: status,
            conclusion: conclusion,
            htmlUrl: nil
        )
        return WorkflowActionGroup(
            headSha: "aabbccdd",
            label: "aabbccd",
            title: "CI",
            headBranch: "main",
            repo: "owner/repo",
            runs: [run],
            jobs: jobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: nil,
            isDimmed: false
        )
    }

    /// Returns a minimal `WorkflowActionGroup` for use in polling tests.
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
