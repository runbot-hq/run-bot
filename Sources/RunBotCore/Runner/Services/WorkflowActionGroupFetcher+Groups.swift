// WorkflowActionGroupFetcher+Groups.swift
// RunBotCore

import Foundation

// MARK: - File-level constants

/// Regex that extracts a PR number from a GitHub merge-ref branch name (e.g. `refs/pull/123/merge`).
let prNumberPattern = #"/(\d+)/"#  // NOSONAR — fixed regex pattern

/// Derives the short display label for an action group row.
///
/// Priority: PR number → branch-embedded number → sha[:7].
/// - Parameter run: The representative `RunPayload` for this group.
/// - Returns: A short label string, e.g. `"#1270"` or `"d6281b"`.
func prLabel(from run: RunPayload) -> String {
  if let pr = run.pullRequests?.first { return "#\(pr.number)" }
  if let branch = run.headBranch,
    let range = branch.range(of: prNumberPattern, options: .regularExpression) {
    let digits = branch[range].filter { $0.isNumber }
    return "#\(digits)"
  }
  return String(run.headSha.prefix(7))
}

// MARK: - Group construction

/// Extension providing group construction, representative selection, title
/// derivation, PR labels, and group sorting for ``WorkflowActionGroupFetcher``.
extension WorkflowActionGroupFetcher {

  /// Sort groups by status priority (ascending), then by creation date (descending).
  func sort(groups: [WorkflowActionGroup]) -> [WorkflowActionGroup] {
    groups.sorted { lhs, rhs in
      if lhs.groupStatus.sortPriority != rhs.groupStatus.sortPriority {
        return lhs.groupStatus.sortPriority < rhs.groupStatus.sortPriority
      }
      return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
  }

  /// Constructs a single `WorkflowActionGroup` for one `(head_sha, event)` bucket.
  ///
  /// Extracted from the `withTaskGroup` `addTask` body so each task closure
  /// stays at depth ≤ 2 and the overall nesting score drops below the
  /// SonarCloud `FunctionNestingDepth:3` threshold.
  func buildActionGroup(
    index: Int,
    groupKey: GroupKey,
    groupRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup]
  ) async -> (Int, WorkflowActionGroup) {
    // `groupRuns` originates from `Dictionary(grouping:)` which never produces an empty
    // value array, so this is expected to always succeed. The guard defends against
    // a future caller constructing the dict incorrectly rather than crashing silently.
    //
    // Representative: the run with the latest creation timestamp, so that re-runs
    // are sorted by their own creation time, not the original run's.
    guard let representative = groupRuns.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") })
    else {
      assertionFailure("buildActionGroup: groupRuns must not be empty (key: \(groupKey))")
      return (
        index,
        WorkflowActionGroup(
          headSha: groupKey.headSha, label: String(groupKey.headSha.prefix(7)),
          title: groupKey.headSha, headBranch: nil, repo: scope, runs: [], jobs: [],
          firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
          normalizedEvent: groupKey.event)
      )
    }
    let label = prLabel(from: representative)
    let title = groupTitle(groupRuns: groupRuns, groupKey: groupKey, representative: representative)
    let runs: [WorkflowRunRef] = groupRuns.map { run in
      WorkflowRunRef(
        id: run.id, name: run.name, status: run.status, conclusion: run.conclusion,
        htmlUrl: run.htmlUrl, runAttempt: run.runAttempt ?? 1)
    }
    let zipGroupKey = ZIPCacheGroupKey(
      repo: scope,
      headSha: groupKey.headSha,
      normalizedEvent: groupKey.event
    )
    let allJobs = await fetchJobsForGroup(groupRuns: groupRuns, scope: scope, cache: cache, cacheKey: groupKey.cacheKey, zipGroupKey: zipGroupKey)
    #if DEBUG
    for job in allJobs {
      log(
        "[TimingTrace][fetch-job] "
          + "group=\(groupKey.cacheKey) "
          + "jobID=\(job.id) "
          + "status=\(job.raw.status) "
          + "rawStart=\(String(describing: job.raw.startedAt)) "
          + "rawEnd=\(String(describing: job.raw.completedAt)) "
          + "parsedStart=\(String(describing: job.raw.startDate)) "
          + "parsedEnd=\(String(describing: job.raw.completedDate))",
        category: .runner
      )
    }
    #endif
    // Route through raw string dates for min/max comparison — ActiveJob exposes
    // startDate/completedDate as parsed Date? via raw.startDate/completedDate, but
    // WorkflowActionGroup.firstJobStartedAt/lastJobCompletedAt take Date?.
    let starts = allJobs.compactMap { $0.raw.startDate }
    let ends = allJobs.compactMap { $0.raw.completedDate }
    #if DEBUG
    log(
      "[TimingTrace][fetch-group] "
        + "group=\(groupKey.cacheKey) "
        + "jobs=\(allJobs.count) "
        + "startCount=\(starts.count) "
        + "endCount=\(ends.count) "
        + "firstStart=\(String(describing: starts.min())) "
        + "lastEnd=\(String(describing: ends.max()))",
      category: .runner
    )
    #endif
    // Optional.flatMap does not accept an async closure — use if let.
    let createdAt: Date?
    if let dateStr = representative.createdAt {
      createdAt = await ISO8601DateParser.shared.parse(dateStr)
    } else {
      createdAt = nil
    }
    return (
      index,
      WorkflowActionGroup(
        headSha: groupKey.headSha,
        label: label,
        title: title,
        headBranch: representative.headBranch,
        repo: scope,
        runs: runs,
        jobs: allJobs,
        firstJobStartedAt: starts.min(),
        lastJobCompletedAt: ends.max(),
        createdAt: createdAt,
        normalizedEvent: groupKey.event
      )
    )
  }

  /// Derives the display title using the normalized group event, not
  /// `representative.event`, so mixed push+PR groups always use the commit subject.
  ///
  /// | Group type | Source |
  /// |---|---|
  /// | `"commit"` (push, PR, mixed) | commit subject, scanning all runs newest-first |
  /// | `workflow_dispatch` / other | `display_title` (e.g. `"Publish"`) |
  /// | Missing metadata | short SHA fallback |
  func groupTitle(
    groupRuns: [RunPayload],
    groupKey: GroupKey,
    representative: RunPayload
  ) -> String {
    let commitSubject = groupRuns
      .reversed()
      .compactMap { run in
        run.headCommit.flatMap { $0.message.components(separatedBy: "\n").first }
      }
      .first
    let fallback = String(groupKey.headSha.prefix(7))
    let rawTitle: String
    if groupKey.event == "commit" {
      rawTitle = commitSubject
        ?? representative.displayTitle
        ?? fallback
    } else {
      rawTitle = representative.displayTitle
        ?? commitSubject
        ?? fallback
    }
    return String(rawTitle.prefix(40))
  }
}
