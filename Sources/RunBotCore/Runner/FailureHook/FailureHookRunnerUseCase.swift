// FailureHookRunnerUseCase.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - FailureHookRunnerUseCase

/// Testable, dependency-injected replacement for the `FailureHookRunner` static enum.
///
/// Fires the per-scope failure-hook terminal command when a `WorkflowActionGroup`
/// transitions to failure. All external dependencies (`ScopePreferencesStore`,
/// `TerminalLauncher`) are injected via protocols so the entire use-case can be
/// unit-tested without hitting `UserDefaults` or spawning Terminal.app.
///
/// ## Migration from `FailureHookRunner`
/// `FailureHookRunner` is now a thin shim that creates this struct with the
/// production adapters (`DefaultScopePreferencesStore`, `DefaultTerminalLauncher`)
/// and delegates to `fireIfNeeded`. All business logic lives here.
///
/// ## Token resolution contract
/// ALL tokens are resolved in Swift before the command string is passed to
/// `/bin/zsh -c`. There must be NO shell variables or `$()` subshells left in the
/// command by the time it reaches the shell — special characters in log content,
/// branch names, etc. would break shell parsing.
///
/// ## Thread safety
/// `FailureHookRunnerUseCase` is `Sendable`. `fireIfNeeded` is `@concurrent` —
/// it runs on the cooperative thread pool, independent of the caller's isolation.
/// `TerminalLauncherProtocol.open(command:)` is dispatched via `MainActor.run`.
public struct FailureHookRunnerUseCase: Sendable {

  /// Default failure-hook command used when the user has not configured a
  /// custom command for the scope. `FailureHookRunner.defaultCommand` forwards
  /// to this constant — it is the canonical definition.
  public static let defaultCommand =
    "cd '$LOCAL_PATH' && gemini -p '$FAILURE_LOG' --model=gemini-2.5-flash --approval-mode=yolo"

  // MARK: Dependencies

  /// Reads per-scope failure-hook preferences from storage.
  public let preferencesStore: any ScopePreferencesStoreProtocol
  /// Opens Terminal.app with the resolved command. Must run on `@MainActor`.
  public let terminalLauncher: any TerminalLauncherProtocol

  /// Creates a use-case wired with the given dependencies.
  public init(
    preferencesStore: any ScopePreferencesStoreProtocol,
    terminalLauncher: any TerminalLauncherProtocol
  ) {
    self.preferencesStore = preferencesStore
    self.terminalLauncher = terminalLauncher
  }

  // MARK: - Public API

  /// Call this whenever a group transitions to done with a failure conclusion.
  /// Fetches failed job/step details on the cooperative thread pool, resolves
  /// tokens, then fires the Terminal command on `@MainActor`.
  ///
  /// Annotated `@concurrent` per R8/R12: runs on the cooperative thread pool,
  /// independent of the caller's isolation domain. This replaces the prior
  /// implicit `nonisolated` behaviour and makes the intent explicit at the
  /// declaration site.
  ///
  /// `group` is not annotated `sending` because it no longer crosses a `Task.detached`
  /// boundary — `fireIfNeeded` is `async` and called inline by `PollResultBuilder`.
  /// `WorkflowActionGroup` is `Sendable`, so `MainActor.run` hops inside this method
  /// are safe without `sending`.
  ///
  /// - Important: If `WorkflowActionGroup` ever drops its `Sendable` conformance,
  ///   restore `sending` on `group` here and in `FailureHookRunner.fireIfNeeded` to
  ///   re-establish the ownership-transfer contract across the async boundary.
  @concurrent
  public func fireIfNeeded(
    group: WorkflowActionGroup,
    scope: String,
    callsite: String = "unknown"
  ) async {
    log(
      "FailureHookRunnerUseCase fireIfNeeded ENTER -- callsite=\(callsite) scope=\(scope) groupID=\(group.id) groupTitle=\(group.title) headSha=\(group.headSha) groupStatus=\(group.groupStatus)",
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
    // Branch filter — skip if a branch filter is set and doesn't match.
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
    log(
      "FailureHookRunnerUseCase storedCommand for scope=\(scope) -> \(storedCommand ?? "<nil -- will use defaultCommand>")",
      category: .failureHook)
    let command = storedCommand ?? FailureHookRunnerUseCase.defaultCommand
    #if DEBUG
      log(
        "FailureHookRunnerUseCase resolved command template (first 200): \(command.prefix(200))",
        category: .failureHook)
    #endif
    let failure = Self.isFailure(group: group)
    let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(
      separator: ", ")
    log(
      "FailureHookRunnerUseCase isFailure=\(failure) for groupID=\(group.id) runs=\(runSummary)",
      category: .failureHook)
    guard failure else {
      log(
        "FailureHookRunnerUseCase SKIP -- group is not a failure, groupID=\(group.id)",
        category: .failureHook)
      return
    }
    log(
      "FailureHookRunnerUseCase ALL CHECKS PASSED -- fetching failed jobs for scope=\(scope) groupID=\(group.id)",
      category: .failureHook)
    let jobs = await Self.fetchFailedJobs(group: group, scope: scope)
    log(
      "FailureHookRunnerUseCase -- fetchFailedJobs returned \(jobs.count) jobs: \(jobs.map { $0.job.name })",
      category: .failureHook)
    let localPath = await preferencesStore.localRepoPath(for: scope) ?? ""
    let resolved = Self.resolveTokens(
      command, group: group, scope: scope, jobs: jobs, localRepoPath: localPath)
    #if DEBUG
      log(
        "FailureHookRunnerUseCase -- resolved command (first 300): \(resolved.prefix(300))",
        category: .failureHook)
    #endif
    log(
      "FailureHookRunnerUseCase -- calling terminalLauncher.open for groupID=\(group.id)",
      category: .failureHook)
    // TerminalLauncherProtocol.open is @MainActor — hop to main actor.
    await MainActor.run {
      terminalLauncher.open(resolved)
      log(
        "FailureHookRunnerUseCase main actor -- terminalLauncher.open returned for groupID=\(group.id)",
        category: .failureHook)
    }
  }

  // MARK: - Internal (testable)

  /// Resolves all `$TOKEN` placeholders in `command` using data from `group`, `scope`, and `jobs`.
  ///
  /// Token map:
  /// - `$LOCAL_PATH`     — absolute path from `ScopePreferencesStoreProtocol.localRepoPath(for:)`
  /// - `$SCOPE`          — `owner/repo` string
  /// - `$BRANCH`         — head branch of the triggering run
  /// - `$COMMIT_SHA`     — full 40-char SHA of the triggering commit
  /// - `$RUN_ID`         — GitHub Actions run ID of the first *failed* run
  /// - `$WORKFLOW_NAME`  — display name of the workflow (from `WorkflowRunRef.name`)
  /// - `$RUN_LINK`       — deep link to the first failed run's Actions page on GitHub
  /// - `$COMMIT_LINK`    — deep link to the commit diff on GitHub
  /// - `$BRANCH_LINK`    — deep link to the branch on GitHub (percent-encoded)
  /// - `$REPO_LINK`      — deep link to the repository root on GitHub
  /// - `$FAILURE_LOG`    — raw log tail (last 150 lines) of the first failed job
  ///
  /// `localRepoPath` is read from the injected `preferencesStore` at call time
  /// (not stored on the struct) so test overrides always take effect.
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
    // `failedRun.id` is an `Int` from the GitHub API — always a pure decimal string.
    // The `group.id` fallback is also numeric: it is `String(runs.map { $0.id }.max() ?? 0)`
    // (see `WorkflowActionGroup.id`), so the fallback path is equally shell-safe.
    let failedRunID = failedRun.map { String($0.id) } ?? group.id
    let runLink = failedRun?.htmlUrl ?? "\(baseURL)/actions/runs/\(failedRunID)"
    let workflowName = failedRun?.name ?? group.runs.first?.name ?? ""
    let commitLink = "\(baseURL)/commit/\(sha)"
    let encodedBranch =
      branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
    let branchLink = "\(baseURL)/tree/\(encodedBranch)"
    let repoLink = baseURL
    let logContent = buildLogContent(group: group, scope: scope, jobs: jobs)
    let escapedLog = singleQuoteEscape(logContent)
    log(
      "FailureHookRunnerUseCase resolveTokens -- $LOCAL_PATH='\(localRepoPath)' $BRANCH='\(branch)'"
      + " $RUN_ID='\(failedRunID)' $WORKFLOW_NAME='\(workflowName)' $COMMIT_SHA='\(sha)'"
      + " logContentBytes=\(escapedLog.count)",
      category: .failureHook)
    return
      command
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

  /// Builds the `$FAILURE_LOG` content from failed job results.
  ///
  /// Falls back to a run-level summary when `jobs` is empty.
  /// Otherwise joins the per-job log entries produced by `logEntry(for:)`.
  ///
  /// Complexity: 2 (one guard branch).
  internal static func buildLogContent(
    group: WorkflowActionGroup,
    scope _: String,
    jobs: [FailedJobResult]
  ) -> String {
    guard !jobs.isEmpty else { return runLevelSummary(group: group) }
    return jobs.map { logEntry(for: $0) }.joined(separator: "\n\n")
  }

  // MARK: - Internal types

  /// The result of fetching a single failed job, including its raw log tail.
  internal struct FailedJobResult {
    /// The failed job payload returned by the GitHub Actions jobs API.
    let job: JobPayload
    /// The last 150 lines of the job log, or `nil` if the log was unavailable.
    let logTail: String?
  }

  // MARK: - Private helpers

  /// Returns a run-level summary used as a fallback when no job details are available.
  ///
  /// Complexity: 2 (one `compactMap` predicate).
  private static func runLevelSummary(group: WorkflowActionGroup) -> String {
    let lines: [String] = group.runs.compactMap { run in
      guard let conclusion = run.conclusion, conclusion.isHookConclusion else { return nil }
      return "FAILED run \(run.id): conclusion=\(conclusion.rawValue) workflow=\(run.name)"
    }
    return lines.joined(separator: "\n")
  }

  /// Produces the log entry string for a single failed job.
  ///
  /// Returns the raw log tail when one is available; otherwise falls back to
  /// a human-readable summary of the failed steps via `stepLines(for:)`.
  ///
  /// Complexity: 2 (one `if let` branch).
  private static func logEntry(for entry: FailedJobResult) -> String {
    if let tail = entry.logTail, !tail.isEmpty {
      return tail
    }
    return stepLines(for: entry.job).joined(separator: "\n")
  }

  /// Formats the failed-step list for a job into printable lines.
  ///
  /// Complexity: 3 (one filter predicate, one isEmpty branch).
  private static func stepLines(for job: JobPayload) -> [String] {
    let failedSteps = job.steps.filter { step in
      guard let conclusion = step.conclusion else { return false }
      return conclusion.isHookConclusion
    }
    var lines: [String] = ["Job: \(job.name) [failed]"]
    if failedSteps.isEmpty {
      lines.append("  (no failed steps reported)")
    } else {
      for step in failedSteps {
        let conclusionStr = step.conclusion?.rawValue ?? step.status.rawValue
        lines.append("  x Step \(step.number): \(step.name) -- \(conclusionStr)")
      }
    }
    return lines
  }

  /// Returns `true` if any run in `group` has a hook-triggering failure conclusion.
  private static func isFailure(group: WorkflowActionGroup) -> Bool {
    group.runs.contains { $0.conclusion?.isHookConclusion == true }
  }

  /// Fetches the failed jobs (and their log tails) for every failure-triggering run in `group`.
  ///
  /// Complexity is kept low by delegating per-run decoding to `fetchJobResults(for:scope:)`
  /// and per-job log fetching to `fetchLogTail(for:scope:)`.
  private static func fetchFailedJobs(
    group: WorkflowActionGroup,
    scope: String
  ) async -> [FailedJobResult] {
    var result: [FailedJobResult] = []
    var seenIDs = Set<Int>()
    for run in group.runs where run.conclusion?.isHookConclusion == true {
      log(
        "FailureHookRunnerUseCase fetchFailedJobs -- fetching jobs for failed run=\(run.id) conclusion=\(run.conclusion?.rawValue ?? "nil")",
        category: .failureHook)
      let jobs = await fetchJobResults(for: run, scope: scope)
      for job in jobs {
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

  /// Fetches and decodes the failed `JobPayload` list for a single run.
  /// Returns an empty array if the API call or JSON decode fails.
  private static func fetchJobResults(
    for run: WorkflowRunRef,
    scope: String
  ) async -> [JobPayload] {
    guard
      let data = await ghAPI(
        "repos/\(scope)/actions/runs/\(run.id)/jobs?per_page=\(GitHubConstants.maxPageSize)")
    else {
      log(
        "FailureHookRunnerUseCase fetchJobResults -- ghAPI returned nil for run=\(run.id)",
        category: .failureHook)
      return []
    }
    guard let resp = try? JSONDecoder().decode(JobsResponse.self, from: data) else {
      log(
        "FailureHookRunnerUseCase fetchJobResults -- JSON decode failed for run=\(run.id) dataBytes=\(data.count)",
        category: .failureHook)
      return []
    }
    log(
      "FailureHookRunnerUseCase fetchJobResults -- run=\(run.id) decoded \(resp.jobs.count) jobs",
      category: .failureHook)
    return resp.jobs.filter { job in
      guard let conclusion = job.conclusion else { return false }
      if !conclusion.isHookConclusion {
        log(
          "FailureHookRunnerUseCase fetchJobResults -- jobID=\(job.id) name=\(job.name) conclusion=\(conclusion.rawValue) -- skipping (not hook-triggering)",
          category: .failureHook)
      }
      return conclusion.isHookConclusion
    }
  }

  /// Fetches the last 150 log lines for a single failed job.
  /// Returns `nil` if the log is unavailable.
  private static func fetchLogTail(
    for job: JobPayload,
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

  /// Escapes `str` so it is safe to embed between single-quotes in a shell command.
  /// Replaces every `'` with `'\''` — the standard POSIX single-quote escape.
  private static func singleQuoteEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "'", with: "'\\''")
  }
}
