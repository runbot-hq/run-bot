// FailureHookRunnerUseCase.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - FailureHookRunnerUseCase

/// Testable, dependency-injected replacement for the `FailureHookRunner` static enum.
public struct FailureHookRunnerUseCase: Sendable {
    public static let defaultCommand =
        "cd '$LOCAL_PATH' && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo"

    // MARK: Dependencies

    public let preferencesStore: any ScopePreferencesStoreProtocol
    public let terminalLauncher: any TerminalLauncherProtocol

    public init(
        preferencesStore: any ScopePreferencesStoreProtocol,
        terminalLauncher: any TerminalLauncherProtocol
    ) {
        self.preferencesStore = preferencesStore
        self.terminalLauncher = terminalLauncher
    }

    // MARK: - Public API

    @concurrent
    public func fireIfNeeded(
        group: WorkflowActionGroup,
        scope: String,
        callsite: String = "unknown"
    ) async {
        log(
            "FailureHookRunnerUseCase fireIfNeeded ENTER -- callsite=\(callsite) scope=\(scope)" +
            " groupID=\(group.id) groupTitle=\(group.title) headSha=\(group.headSha)" +
            " groupStatus=\(group.groupStatus)",
            category: .failureHook)

        let hookEnabled = await preferencesStore.failureHookEnabled(for: scope)
        log(
            "FailureHookRunnerUseCase failureHookEnabled for scope=\(scope) -> \(hookEnabled)",
            category: .failureHook)
        guard hookEnabled else {
            log(
                "FailureHookRunnerUseCase SKIP -- hook not enabled for scope=\(scope)",
                category: .failureHook)
            return
        }

        let filterBranch = await preferencesStore.failureHookBranch(for: scope)
        if let filter = filterBranch {
            let groupBranch = group.headBranch ?? ""
            guard groupBranch == filter else {
                log(
                    "FailureHookRunnerUseCase SKIP -- branch filter '\(filter)' != group branch '\(groupBranch)'",
                    category: .failureHook)
                return
            }
            log(
                "FailureHookRunnerUseCase branch filter '\(filter)' MATCHED group branch '\(groupBranch)'",
                category: .failureHook)
        }

        let storedCommand = await preferencesStore.failureHookCommand(for: scope)
        let command = storedCommand ?? FailureHookRunnerUseCase.defaultCommand

        let failure = Self.isFailure(group: group)
        let runSummary = group.runs
            .map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }
            .joined(separator: ", ")
        log(
            "FailureHookRunnerUseCase isFailure=\(failure) for groupID=\(group.id) runs=\(runSummary)",
            category: .failureHook)
        guard failure else {
            log(
                "FailureHookRunnerUseCase SKIP -- group is not a failure, groupID=\(group.id)",
                category: .failureHook)
            return
        }

        let jobs = await Self.fetchFailedJobs(group: group, scope: scope)
        log(
            "FailureHookRunnerUseCase -- fetchFailedJobs returned \(jobs.count) jobs:" +
            " \(jobs.map { $0.job.name })",
            category: .failureHook)

        let localPath = await preferencesStore.localRepoPath(for: scope) ?? ""
        let resolved = Self.resolveTokens(
            command,
            group: group,
            scope: scope,
            jobs: jobs,
            localRepoPath: localPath)

        await MainActor.run {
            terminalLauncher.open(resolved)
        }
    }

    // MARK: - Internal (testable)

    internal static func resolveTokens(
        _ command: String,
        group: WorkflowActionGroup,
        scope: String,
        jobs: [FailedJobResult],
        localRepoPath: String = ""
    ) -> String {
        let branch = group.headBranch ?? ""
        let sha = group.headSha
        let baseURL = "https://github.com/\(scope)"
        let failedRun = group.runs.first(where: { $0.conclusion?.isHookConclusion == true })
        let failedRunID = failedRun.map { String($0.id) } ?? group.id
        let runLink = failedRun?.htmlUrl ?? "\(baseURL)/actions/runs/\(failedRunID)"
        let workflowName = failedRun?.name ?? group.runs.first?.name ?? ""
        let commitLink = "\(baseURL)/commit/\(sha)"
        let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        let branchLink = "\(baseURL)/tree/\(encodedBranch)"
        let repoLink = baseURL
        let logContent = buildLogContent(group: group, scope: scope, jobs: jobs)
        let escapedLog = singleQuoteEscape(logContent)

        return command
            .replacingOccurrences(of: "$LOCAL_PATH", with: singleQuoteEscape(localRepoPath))
            .replacingOccurrences(of: "$SCOPE", with: singleQuoteEscape(scope))
            .replacingOccurrences(of: "$BRANCH", with: singleQuoteEscape(branch))
            .replacingOccurrences(of: "$COMMIT_SHA", with: singleQuoteEscape(sha))
            .replacingOccurrences(of: "$RUN_ID", with: singleQuoteEscape(failedRunID))
            .replacingOccurrences(of: "$WORKFLOW_NAME", with: singleQuoteEscape(workflowName))
            .replacingOccurrences(of: "$RUN_LINK", with: runLink)
            .replacingOccurrences(of: "$COMMIT_LINK", with: commitLink)
            .replacingOccurrences(of: "$BRANCH_LINK", with: branchLink)
            .replacingOccurrences(of: "$REPO_LINK", with: repoLink)
            .replacingOccurrences(of: "$FAILURE_LOG", with: escapedLog)
    }

    internal static func buildLogContent(
        group: WorkflowActionGroup,
        scope _: String,
        jobs: [FailedJobResult]
    ) -> String {
        guard !jobs.isEmpty else { return runLevelSummary(group: group) }
        return jobs.map { logEntry(for: $0) }.joined(separator: "\n\n")
    }

    // MARK: - Internal types

    internal struct FailedJobResult {
        let job: GitHubJob
        let logTail: String?
    }

    // MARK: - Private helpers

    private static func runLevelSummary(group: WorkflowActionGroup) -> String {
        let lines: [String] = group.runs.compactMap { run in
            guard let conclusion = run.conclusion, conclusion.isHookConclusion else { return nil }
            return "FAILED run \(run.id): conclusion=\(conclusion.rawValue) workflow=\(run.name)"
        }
        return lines.joined(separator: "\n")
    }

    private static func logEntry(for entry: FailedJobResult) -> String {
        if let tail = entry.logTail, !tail.isEmpty { return tail }
        return stepLines(for: entry.job).joined(separator: "\n")
    }

    private static func stepLines(for job: GitHubJob) -> [String] {
        // GitHubStep.conclusion is String? — map through JobConclusion(rawString:) to use isHookConclusion.
        // init(rawString:) never fails (returns .unknown for unrecognised values) so no optional needed.
        let failedSteps = job.steps.filter { step in
            guard let raw = step.conclusion else { return false }
            return JobConclusion(rawString: raw).isHookConclusion
        }
        var lines: [String] = ["Job: \(job.name) [failed]"]
        if failedSteps.isEmpty {
            lines.append("  (no failed steps reported)")
        } else {
            for step in failedSteps {
                let conclusionStr = step.conclusion ?? step.status
                lines.append("  x Step \(step.number): \(step.name) -- \(conclusionStr)")
            }
        }
        return lines
    }

    private static func isFailure(group: WorkflowActionGroup) -> Bool {
        group.runs.contains { $0.conclusion?.isHookConclusion == true }
    }

    private static func fetchFailedJobs(
        group: WorkflowActionGroup,
        scope: String
    ) async -> [FailedJobResult] {
        guard let parsedScope = Scope.parse(scope) else {
            log(
                "FailureHookRunnerUseCase fetchFailedJobs -- invalid scope: \(scope)",
                category: .failureHook)
            return []
        }
        var result: [FailedJobResult] = []
        var seenIDs = Set<Int>()
        for run in group.runs where run.conclusion?.isHookConclusion == true {
            log(
                "FailureHookRunnerUseCase fetchFailedJobs -- fetching jobs for failed run=\(run.id)" +
                " conclusion=\(run.conclusion?.rawValue ?? "nil")",
                category: .failureHook)
            let allJobs = await fetchJobs(runID: run.id, scope: parsedScope)
            // GitHubJob.conclusion is String? — map through JobConclusion(rawString:) to use isHookConclusion.
            // init(rawString:) never fails so no optional chaining needed.
            let failedJobs = allJobs.filter { job in
                guard let raw = job.conclusion else { return false }
                return JobConclusion(rawString: raw).isHookConclusion
            }
            for job in failedJobs {
                guard seenIDs.insert(job.id).inserted else { continue }
                let tail = await fetchLogTail(for: job, scope: scope)
                result.append(FailedJobResult(job: job, logTail: tail))
            }
        }
        log(
            "FailureHookRunnerUseCase fetchFailedJobs -- total \(result.count) unique failed jobs returned",
            category: .failureHook)
        return result
    }

    private static func fetchLogTail(
        for job: GitHubJob,
        scope: String
    ) async -> String? {
        log(
            "FailureHookRunnerUseCase fetchLogTail -- fetching log for jobID=\(job.id) name=\(job.name)",
            category: .failureHook)
        guard let fullLog = await LogFetcher().fetchJobLog(jobID: job.id, scope: scope) else {
            log(
                "FailureHookRunnerUseCase fetchLogTail -- jobID=\(job.id) fetchJobLog returned nil",
                category: .failureHook)
            return nil
        }
        let lines = fullLog.components(separatedBy: "\n")
        let tail = lines.suffix(150).joined(separator: "\n")
        log(
            "FailureHookRunnerUseCase fetchLogTail -- jobID=\(job.id) log lines=\(lines.count) kept last 150",
            category: .failureHook)
        return tail
    }

    private static func singleQuoteEscape(_ str: String) -> String {
        str.replacingOccurrences(of: "'", with: "'\\''")
    }
}
