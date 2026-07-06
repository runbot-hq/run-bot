// WorkflowActionGroupFetch.swift
// RunBotCore
import Foundation
import GitHubClient
import os

// MARK: - File-level constants
/// Regex that extracts a PR number from a GitHub merge-ref branch name (e.g. `refs/pull/123/merge`).
private let prNumberPattern = #"/(\d+)/"#  // NOSONAR — fixed regex pattern

/// Maximum number of in-progress/inconclusive jobs refreshed concurrently per run.
///
/// Capped to avoid a thundering-herd of single-job API calls when a run has
/// many steps still in-progress simultaneously (e.g. a large matrix job).
///
/// **Determinism:** `initial` is sorted by `job.id` (ascending) before slicing,
/// so the first `maxRefreshConcurrency` jobs selected are always the lowest-ID
/// jobs needing refresh — not whichever tasks happened to complete first in the
/// preceding `withTaskGroup`. Without the sort, `withTaskGroup` completion order
/// is non-deterministic and different jobs could be skipped on every poll cycle,
/// causing some jobs to serve stale data indefinitely in a large matrix run where
/// all jobs finish concurrently and no slot ever frees before the cap is re-evaluated.
private let maxRefreshConcurrency = 3

// MARK: - Codable helpers (private to this file)

/// Response envelope for the workflow runs list API endpoint.
private struct ActionRunsResponse: Codable {
  /// The list of workflow runs returned by the API.
  let workflowRuns: [RunPayload]
  /// Maps the snake_case `workflow_runs` key to the camelCase Swift property.
  enum CodingKeys: String, CodingKey {
    /// Maps `workflow_runs` JSON key to `workflowRuns`.
    case workflowRuns = "workflow_runs"
  }
}

/// Minimal workflow run payload used for group construction.
///
/// `status` and `conclusion` are decoded directly as typed `JobStatus`/`JobConclusion`
/// values via their `Codable` conformances. Unknown raw strings fall through to
/// `.unknown(String)` rather than failing the decode.
private struct RunPayload: Codable {
  /// The unique run identifier.
  let id: Int
  /// The workflow name.
  let name: String
  /// The current run status.
  let status: JobStatus
  /// The run conclusion, if completed.
  let conclusion: JobConclusion?
  /// The branch name the run is targeting.
  let headBranch: String?
  /// The full SHA of the head commit.
  let headSha: String
  /// The human-readable display title shown in the GitHub UI.
  let displayTitle: String?
  /// ISO-8601 timestamp when the run was created.
  let createdAt: String?
  /// URL to the run in the GitHub web UI.
  let htmlUrl: String?
  /// The head commit metadata.
  let headCommit: HeadCommit?
  /// Pull request references associated with this run.
  let pullRequests: [PRRef]?
  /// CodingKeys mapping snake_case API fields to camelCase Swift properties.
  enum CodingKeys: String, CodingKey {
    /// Maps the `id` JSON field.
    case id
    /// Maps the `name` JSON field.
    case name
    /// Maps the `status` JSON field.
    case status
    /// Maps the `conclusion` JSON field.
    case conclusion
    /// Maps the `head_branch` JSON field.
    case headBranch = "head_branch"
    /// Maps the `head_sha` JSON field.
    case headSha = "head_sha"
    /// Maps the `display_title` JSON field.
    case displayTitle = "display_title"
    /// Maps the `created_at` JSON field.
    case createdAt = "created_at"
    /// Maps the `html_url` JSON field.
    case htmlUrl = "html_url"
    /// Maps the `head_commit` JSON field.
    case headCommit = "head_commit"
    /// Maps the `pull_requests` JSON field.
    case pullRequests = "pull_requests"
  }
}

/// The first line of the head commit message, used as a fallback display title.
private struct HeadCommit: Codable {
  /// The full commit message (only the first line is used).
  let message: String
}

/// A pull request reference attached to a workflow run.
private struct PRRef: Codable {
  /// The pull request number.
  let number: Int
}

/// Response envelope for the jobs list API endpoint (`/runs/{id}/jobs`).
///
/// Replaces the deleted `JobsResponse` type from the pre-Step-8 code.
/// The GitHub API returns `{ "jobs": [ ... ] }` — this struct unwraps that envelope.
/// Decodable-only: `GitHubJob` does not conform to `Encodable`, so `Codable` would
/// fail to synthesise and is unnecessary — this struct is used only for decoding.
private struct GitHubJobsWrapper: Decodable {
  /// The list of jobs returned by the API.
  let jobs: [GitHubJob]
}

/// Derives the short display label for an action group row.
///
/// Priority: PR number → branch-embedded number → sha[:7].
/// - Parameter run: The representative `RunPayload` for this group.
/// - Returns: A short label string, e.g. `"#1270"` or `"d6281b"`.
private func prLabel(from run: RunPayload) -> String {
  if let pr = run.pullRequests?.first { return "#\(pr.number)" }
  if let branch = run.headBranch,
    let range = branch.range(of: prNumberPattern, options: .regularExpression) {
    let digits = branch[range].filter { $0.isNumber }
    return "#\(digits)"
  }
  return String(run.headSha.prefix(7))
}

// MARK: - WorkflowActionGroupFetcher

/// Fetches and groups workflow action groups for one or more repo scopes.
///
/// Accepts any `GitHubTransportProtocol` conformer so the hot polling path
/// is testable without live network access. Production callers use the
/// default `sharedGitHubTransport`; tests inject a stub.
///
/// - SeeAlso: ``GitHubTransportProtocol``
public struct WorkflowActionGroupFetcher: Sendable, WorkflowActionGroupFetcherProtocol {

  /// The transport used for all GitHub API calls made by this fetcher.
  private let transport: any GitHubTransportProtocol

  /// Shared JSON decoder reused across all API response decoding.
  ///
  /// Owned by the struct (rather than captured from file scope) so this type is
  /// self-contained and safe to use across actor boundaries. `JSONDecoder.decode`
  /// is stateless and safe for concurrent use. All configuration (key decoding
  /// strategy, date decoding strategy, etc.) MUST be set at the declaration site
  /// below — never mutated after initialisation. Post-init mutation would race
  /// with concurrent `withTaskGroup` / `@concurrent` decode calls.
  /// - Note: A `struct` stored `let` does not need `nonisolated` — `JSONDecoder` is a
  ///   class, so all struct copies share the same instance, but
  ///   `JSONDecoder.decode(_:from:)` is stateless and safe for concurrent reads.
  ///   Principle 17's `nonisolated` requirement applies to actor-isolated properties.
  private let decoder = JSONDecoder()

  /// Creates a fetcher backed by the given transport.
  ///
  /// - Parameter transport: Defaults to `sharedGitHubTransport` so existing
  ///   production call sites need no change beyond switching to the instance method.
  public init(transport: any GitHubTransportProtocol = sharedGitHubTransport) {
    self.transport = transport
  }

  // MARK: - Fetch + Group

  /// Fetches active workflow runs for a repo scope, groups them by `head_sha`,
  /// enriches each group with its flattened job list, and returns groups sorted:
  /// in-progress first, then queued, then completed — newest first within each tier.
  ///
  /// All three status fetches (in_progress, queued, completed) run concurrently.
  /// Per-run job fetches within each group also run concurrently.
  /// Date parsing goes through `ISO8601DateParser.shared` — one actor, one formatter.
  ///
  /// - Note: `@concurrent` is applied only to this public entry point so that
  ///   callers on an actor-bound context (e.g. `RunnerStore`'s custom actor executor) hop
  ///   off the actor executor for the entire fetch pipeline. The private helpers
  ///   (`buildActionGroup`, `fetchJobsForGroup`, `fetchJobsForRun`) are internal
  ///   to `withTaskGroup` and already run on the task's executor, so they don't
  ///   need the annotation. See also: SE-0420 (``@_unsupportedInheritActorContext``).
  @concurrent
  public func fetch(for scope: String, cache: [String: WorkflowActionGroup] = [:]) async -> [WorkflowActionGroup] {
    guard scope.contains("/") else {
      log("fetchActionGroups -- skipping org scope \(scope)", category: .runner)
      return []
    }

    // Fetch in_progress, queued, and completed runs concurrently.
    async let inProgressData = transport.apiAsync(
      "repos/\(scope)/actions/runs?status=in_progress&per_page=\(GitHubConstants.activeRunsPageSize)"
    )
    async let queuedData = transport.apiAsync(
      "repos/\(scope)/actions/runs?status=queued&per_page=\(GitHubConstants.activeRunsPageSize)")
    async let completedData = transport.apiAsync(
      "repos/\(scope)/actions/runs?status=completed&per_page=\(GitHubConstants.maxPageSize)")
    let (ipData, qData, cData) = await (inProgressData, queuedData, completedData)

    var runPayloads: [RunPayload] = []
    var seenIDs = Set<Int>()

    for data in [ipData, qData].compactMap({ $0 }) {
      decodeRuns(from: data, into: &runPayloads, seenIDs: &seenIDs)
    }

    var bySha: [String: [RunPayload]] = [:]
    for run in runPayloads { bySha[run.headSha, default: []].append(run) }

    // Phase 2: fetch recently completed runs and merge into ALL SHA groups.
    if let data = cData {
      decodeRuns(from: data, into: &runPayloads, seenIDs: &seenIDs)
      // Re-constructing bySha entirely is safer and cleaner than mutating the old dict
      bySha.removeAll(keepingCapacity: true)
      for run in runPayloads { bySha[run.headSha, default: []].append(run) }
    }

    // Build groups concurrently — index-keyed to preserve insertion order.
    let shaEntries = Array(bySha)
    var groups = Array(repeating: WorkflowActionGroup?.none, count: shaEntries.count)
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
      for (i, (sha, shaRuns)) in shaEntries.enumerated() {
        group.addTask {
          await self.buildActionGroup(
            index: i, sha: sha, shaRuns: shaRuns, scope: scope, cache: cache)
        }
      }
      for await (i, actionGroup) in group { groups[i] = actionGroup }
    }

    let result = groups.compactMap { $0 }
    log("fetchActionGroups -- \(result.count) group(s) for \(scope)", category: .runner)
    return sort(groups: result)
  }

  // MARK: - Private helpers

  /// Decodes workflow runs from the given API response data, appending new (unseen) runs
  /// to the `payloads` array. Duplicates are silently skipped via `seenIDs`.
  private func decodeRuns(from data: Data, into payloads: inout [RunPayload], seenIDs: inout Set<Int>) {
    guard let resp = try? decoder.decode(ActionRunsResponse.self, from: data) else { return }
    for run in resp.workflowRuns {
      guard seenIDs.insert(run.id).inserted else { continue }
      payloads.append(run)
    }
  }

  /// Sorts action groups by sort priority (ascending), then by creation date (descending).
  private func sort(groups: [WorkflowActionGroup]) -> [WorkflowActionGroup] {
    groups.sorted { lhs, rhs in
      if lhs.groupStatus.sortPriority != rhs.groupStatus.sortPriority {
        return lhs.groupStatus.sortPriority < rhs.groupStatus.sortPriority
      }
      return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
  }

  /// Constructs a single `WorkflowActionGroup` for one `head_sha` bucket.
  ///
  /// Extracted from the `withTaskGroup` `addTask` body so each task closure
  /// stays at depth ≤ 2 and the overall nesting score drops below the
  /// SonarCloud `FunctionNestingDepth:3` threshold.
  private func buildActionGroup(
    index: Int,
    sha: String,
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup]
  ) async -> (Int, WorkflowActionGroup) {
    // `shaRuns` originates from `Dictionary(grouping:)` which never produces an empty
    // value array, so this is expected to always succeed. The guard defends against
    // a future caller constructing the dict incorrectly rather than crashing silently.
    guard let representative = shaRuns.max(by: { ($0.createdAt ?? "") < ($1.createdAt ?? "") })
    else {
      assertionFailure("buildActionGroup: shaRuns must not be empty (sha: \(sha))")
      return (
        index,
        WorkflowActionGroup(
          headSha: sha, label: String(sha.prefix(7)),
          title: sha, headBranch: nil, repo: scope, runs: [], jobs: [],
          firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil)
      )
    }
    let label = prLabel(from: representative)
    let rawTitle =
      representative.displayTitle
      ?? representative.headCommit.map { commit in
        String(commit.message.components(separatedBy: "\n").first ?? "")
      }
      ?? String(sha.prefix(7))
    let title = String(rawTitle.prefix(40))
    let runs: [WorkflowRunRef] = shaRuns.map { run in
      WorkflowRunRef(
        id: run.id, name: run.name, status: run.status, conclusion: run.conclusion,
        htmlUrl: run.htmlUrl)
    }
    let allJobs = await fetchJobsForGroup(shaRuns: shaRuns, scope: scope, cache: cache, sha: sha)
    // Route through raw string dates for min/max comparison — ActiveJob exposes
    // startDate/completedDate as parsed Date? via raw.startDate/completedDate, but
    // WorkflowActionGroup.firstJobStartedAt/lastJobCompletedAt take Date?.
    let starts = allJobs.compactMap { $0.raw.startDate }
    let ends = allJobs.compactMap { $0.raw.completedDate }
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
        headSha: sha,
        label: label,
        title: title,
        headBranch: representative.headBranch,
        repo: scope,
        runs: runs,
        jobs: allJobs,
        firstJobStartedAt: starts.min(),
        lastJobCompletedAt: ends.max(),
        createdAt: createdAt
      )
    )
  }

  /// Returns the flattened job list for all runs sharing a `head_sha`.
  ///
  /// Uses the SHA-keyed cache when all cached jobs are concluded and none have
  /// in-progress steps, avoiding redundant API calls for finished groups.
  /// Falls back to a live fetch via `fetchJobsForRun` when the cache is stale or missing.
  ///
  /// Per-run job fetches run concurrently via `withTaskGroup`.
  private func fetchJobsForGroup(
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    sha: String
  ) async -> [ActiveJob] {
    if let cached = cache[sha],
      cached.repo == scope,
      !cached.jobs.isEmpty,
      // Both conditions required: a job can be concluded while one of its steps
      // is still marked in-progress (stale step data from a mid-poll snapshot).
      // Serving that cache entry would show a spinning step on an already-finished job.
      // ActiveJob exposes jobConclusion (JobConclusion?), not conclusion (String?).
      cached.jobs.allSatisfy({ $0.jobConclusion != nil }),
      // GitHubStep.status is raw String — use stepStatus typed accessor.
      !cached.jobs.contains(where: { $0.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress }) }) {
      return cached.jobs
    }

    var fetched: [ActiveJob] = []
    var seenJobIDs = Set<Int>()
    await withTaskGroup(of: [ActiveJob].self) { group in
      for runID in shaRuns.map({ $0.id }) {
        group.addTask { await self.fetchJobsForRun(runID, scope: scope) }
      }
      for await jobs in group {
        for job in jobs where seenJobIDs.insert(job.id).inserted {
          fetched.append(job)
        }
      }
    }
    fetched.sort { $0.id < $1.id }
    return fetched
  }

  /// Fetches and decodes the job list for a single run ID, refreshing any
  /// in-progress or inconclusive jobs with a targeted single-job API call.
  ///
  /// - Note: `filter=latest` is intentionally omitted — it drops queued jobs that
  ///   haven't started yet, causing `jobsTotal` to be lower than the detail view.
  ///   `per_page=100` is the GitHub API maximum and covers all realistic job counts.
  ///
  /// Refresh calls for in-progress/inconclusive jobs run concurrently,
  /// capped at `maxRefreshConcurrency` to avoid a thundering-herd of single-job
  /// API calls on runs with many simultaneously in-progress steps.
  /// `initial` is sorted by `job.id` ascending before slicing so the cap always
  /// selects the same lowest-ID jobs — not whichever tasks finished first in the
  /// preceding `withTaskGroup` (whose completion order is non-deterministic).
  /// All date parsing goes through `ISO8601DateParser.shared`.
  private func fetchJobsForRun(_ runID: Int, scope: String) async -> [ActiveJob] {
    guard
      let data = await transport.apiAsync(
        "repos/\(scope)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)")
    else {
      return []
    }
    // JobsResponse was removed in the Step 8 refactor. Use GitHubJobsWrapper which
    // decodes the `{ "jobs": [...] }` envelope that the GitHub API returns.
    let wrapper: GitHubJobsWrapper
    do {
      wrapper = try decoder.decode(GitHubJobsWrapper.self, from: data)
    } catch {
      log(
        "fetchJobsForRun — ⚠️ decode failed for runID=\(runID) scope=\(scope): \(error)",
        category: .runner)
      return []
    }

    let initial = await withTaskGroup(of: ActiveJob.self) { group in
      for payload in wrapper.jobs {
        group.addTask { ActiveJob(raw: payload) }
      }
      var out: [ActiveJob] = []
      for await job in group { out.append(job) }
      // Sort by id so the refresh cap below is deterministic across poll cycles.
      return out.sorted { $0.id < $1.id }
    }

    // Refresh in-progress/inconclusive jobs concurrently, capped at maxRefreshConcurrency.
    // `initial` is already sorted by job.id (above), so `.prefix(maxRefreshConcurrency)`
    // always selects the same lowest-ID jobs needing refresh — independent of task
    // completion order. Without the sort, a matrix run with N > maxRefreshConcurrency
    // simultaneous jobs could starve the same job indefinitely if it consistently
    // lands beyond position maxRefreshConcurrency in whichever order the group finishes.
    // Note: `idx` is the position in `initial`/`result`, not the position in `needsRefresh`.
    // The `.prefix(maxRefreshConcurrency)` reduces the number of refresh tasks, but the
    // original enumerated indices are preserved for the `result[idx]` write-back below.
    let allNeedingRefresh = initial.enumerated().filter { (_, job: ActiveJob) in
      // ActiveJob exposes jobConclusion (JobConclusion?), not conclusion (String?).
      // GitHubStep.status is raw String — use stepStatus typed accessor.
      job.jobConclusion == nil || job.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress })
    }
    let needsRefresh = allNeedingRefresh.prefix(maxRefreshConcurrency)
    let skippedCount = allNeedingRefresh.count - needsRefresh.count
    if skippedCount > 0 {
      log(
        "fetchJobsForRun -- \(skippedCount) in-progress job(s) skipped beyond cap (\(maxRefreshConcurrency)) — "
          + "these jobs will serve stale step data this cycle; they rotate into the refresh window as lower-ID jobs conclude",
        category: .runner)
    }
    guard !needsRefresh.isEmpty else { return initial }

    var result = initial
    await withTaskGroup(of: (Int, ActiveJob?).self) { group in
      for (idx, job) in needsRefresh {
        group.addTask { (idx, await self.refreshedJob(job, scope: scope)) }
      }
      for await (idx, updated) in group {
        if let updated { result[idx] = updated }
      }
    }
    return result
  }

  /// Fetches a fresh copy of `job` from the API and returns an updated ``ActiveJob`` if the
  /// response contains meaningful new data, or `nil` if the original should be kept as-is.
  ///
  /// A non-`nil` return means either:
  /// - The job now has a `conclusion` (it finished) — return the fully-fresh job, or
  /// - The live step list is complete (non-empty, none in-progress) — merge timing fields
  ///   from the fresh payload onto the original via `copying()` so no other fields are lost.
  ///
  /// See commit f8264d3 for the original bug this merge strategy guards against.
  private func refreshedJob(_ job: ActiveJob, scope: String) async -> ActiveJob? {
    guard
      let freshData = await transport.apiAsync("repos/\(scope)/actions/jobs/\(job.id)"),
      // JobPayload was renamed to GitHubJob in the Step 8 refactor.
      let fresh = try? decoder.decode(GitHubJob.self, from: freshData)
    else { return nil }
    let freshJob = ActiveJob(raw: fresh)
    if fresh.conclusion != nil { return freshJob }
    // GitHubStep.status is raw String — use stepStatus typed accessor.
    let hasBetterSteps =
      !freshJob.steps.isEmpty
      && !freshJob.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress })
    guard hasBetterSteps else { return nil }
    // Use copying() helpers so any future field added to ActiveJob is
    // automatically preserved from `job` without a manual update here.
    // `.copying(createdAt:)` is included explicitly even though copying()
    // already carries all unlisted fields forward unchanged — the original
    // bug (commit f8264d3) dropped createdAt in an earlier version of this
    // function that used the full constructor. The explicit call is
    // belt-and-suspenders: it documents intent, costs nothing at runtime,
    // and guards against a future refactor that switches back to a
    // constructor form accidentally dropping the field again.
    // ActiveJob has no direct startedAt/completedAt/createdAt — route through raw.
    return
      job
      .copying(runnerName: freshJob.runnerName ?? job.runnerName)
      .copying(startedAt: freshJob.raw.startedAt ?? job.raw.startedAt)
      .copying(completedAt: freshJob.raw.completedAt ?? job.raw.completedAt)
      .copying(createdAt: freshJob.raw.createdAt ?? job.raw.createdAt)
      .copying(steps: freshJob.steps)
  }
}
