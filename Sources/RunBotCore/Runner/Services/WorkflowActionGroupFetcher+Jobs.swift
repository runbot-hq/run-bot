// WorkflowActionGroupFetcher+Jobs.swift
// RunBotCore

import Foundation
import GitHubClient
import os

// MARK: - File-level constants

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
let maxRefreshConcurrency = 3

// MARK: - Job fetching

/// Extension providing per-run job fetching, cache validation, bounded concurrent
/// refresh of in-progress jobs, and job deduplication for ``WorkflowActionGroupFetcher``.
extension WorkflowActionGroupFetcher {

  /// Returns the flattened job list for all runs sharing a `(head_sha, event)` group key.
  ///
  /// Uses the cache when all cached jobs are concluded and none have
  /// in-progress steps, avoiding redundant API calls for finished groups.
  /// Falls back to a live fetch via `fetchJobsForRun` when the cache is stale or missing.
  ///
  /// Per-run job fetches run concurrently via `withTaskGroup`.
  func fetchJobsForGroup(
    groupRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    cacheKey: String,
    zipGroupKey: ZIPCacheGroupKey? = nil
  ) async -> [ActiveJob] {
    if let cached = cache[cacheKey],
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
      for run in groupRuns {
        group.addTask { await self.fetchJobsForRun(run.id, scope: scope, zipGroupKey: zipGroupKey) }
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
  func fetchJobsForRun(_ runID: Int, scope: String, zipGroupKey: ZIPCacheGroupKey? = nil) async -> [ActiveJob] {
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
        group.addTask { ActiveJob(raw: payload, zipCacheGroupKey: zipGroupKey) }
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
  func refreshedJob(_ job: ActiveJob, scope: String) async -> ActiveJob? {
    guard
      let freshData = await transport.apiAsync("repos/\(scope)/actions/jobs/\(job.id)"),
      // JobPayload was renamed to GitHubJob in the Step 8 refactor.
      let fresh = try? decoder.decode(GitHubJob.self, from: freshData)
    else { return nil }
    let freshJob = ActiveJob(raw: fresh, zipCacheGroupKey: job.zipCacheGroupKey)
    if fresh.conclusion != nil { return freshJob }
    // GitHubStep.status is raw String — use stepStatus typed accessor.
    let hasBetterSteps =
      !freshJob.steps.isEmpty
      && !freshJob.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress })
    guard hasBetterSteps else { return nil }
    // Use copying() helpers so any future field is preserved automatically.
    // createdAt is `let` on GitHubJob and cannot be mutated via copying(update:).
    return
      job
      .copying(runnerName: freshJob.runnerName ?? job.runnerName)
      .copying(startedAt: freshJob.raw.startedAt ?? job.raw.startedAt)
      .copying(completedAt: freshJob.raw.completedAt ?? job.raw.completedAt)
      .copying(steps: freshJob.steps)
  }
}
