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
    case id
    case name
    case status
    case conclusion
    case headBranch = "head_branch"
    case headSha = "head_sha"
    case displayTitle = "display_title"
    case createdAt = "created_at"
    case htmlUrl = "html_url"
    case headCommit = "head_commit"
    case pullRequests = "pull_requests"
  }
}

/// The first line of the head commit message, used as a fallback display title.
private struct HeadCommit: Codable {
  let message: String
}

/// A pull request reference attached to a workflow run.
private struct PRRef: Codable {
  let number: Int
}

/// Response envelope for the jobs list API endpoint (`/runs/{id}/jobs`).
///
/// Replaces the deleted `JobsResponse` type from the pre-Step-8 code.
/// The GitHub API returns `{ "jobs": [ ... ] }` — this struct unwraps that envelope.
/// `Decodable`-only because `GitHubJob` is `Decodable`-only (no `Encodable` synthesis).
private struct GitHubJobsWrapper: Decodable {
  /// The list of jobs returned by the API.
  let jobs: [GitHubJob]
}

/// Derives the short display label for an action group row.
///
/// Priority: PR number → branch-embedded number → sha[:7].
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
public struct WorkflowActionGroupFetcher: Sendable, WorkflowActionGroupFetcherProtocol {

  private let transport: any GitHubTransportProtocol
  private let decoder = JSONDecoder()

  public init(transport: any GitHubTransportProtocol = sharedGitHubTransport) {
    self.transport = transport
  }

  // MARK: - Fetch + Group

  @concurrent
  public func fetch(for scope: String, cache: [String: WorkflowActionGroup] = [:]) async -> [WorkflowActionGroup] {
    guard scope.contains("/") else {
      log("fetchActionGroups -- skipping org scope \(scope)", category: .runner)
      return []
    }

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

    if let data = cData {
      decodeRuns(from: data, into: &runPayloads, seenIDs: &seenIDs)
      bySha.removeAll(keepingCapacity: true)
      for run in runPayloads { bySha[run.headSha, default: []].append(run) }
    }

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

  private func decodeRuns(from data: Data, into payloads: inout [RunPayload], seenIDs: inout Set<Int>) {
    guard let resp = try? decoder.decode(ActionRunsResponse.self, from: data) else { return }
    for run in resp.workflowRuns {
      guard seenIDs.insert(run.id).inserted else { continue }
      payloads.append(run)
    }
  }

  private func sort(groups: [WorkflowActionGroup]) -> [WorkflowActionGroup] {
    groups.sorted { lhs, rhs in
      if lhs.groupStatus.sortPriority != rhs.groupStatus.sortPriority {
        return lhs.groupStatus.sortPriority < rhs.groupStatus.sortPriority
      }
      return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
    }
  }

  private func buildActionGroup(
    index: Int,
    sha: String,
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup]
  ) async -> (Int, WorkflowActionGroup) {
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
    let starts = allJobs.compactMap { $0.raw.startDate }
    let ends = allJobs.compactMap { $0.raw.completedDate }
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

  private func fetchJobsForGroup(
    shaRuns: [RunPayload],
    scope: String,
    cache: [String: WorkflowActionGroup],
    sha: String
  ) async -> [ActiveJob] {
    if let cached = cache[sha],
      cached.repo == scope,
      !cached.jobs.isEmpty,
      cached.jobs.allSatisfy({ $0.jobConclusion != nil }),
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

  private func fetchJobsForRun(_ runID: Int, scope: String) async -> [ActiveJob] {
    guard
      let data = await transport.apiAsync(
        "repos/\(scope)/actions/runs/\(runID)/jobs?per_page=\(GitHubConstants.maxPageSize)")
    else {
      return []
    }
    // JobsResponse was removed in Step 8. GitHubJobsWrapper decodes { "jobs": [...] }.
    // Decodable-only because GitHubJob does not conform to Encodable.
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
        group.addTask { await ISO8601DateParser.shared.makeJob(from: payload) }
      }
      var out: [ActiveJob] = []
      for await job in group { out.append(job) }
      return out.sorted { $0.id < $1.id }
    }

    let allNeedingRefresh = initial.enumerated().filter { (_, job: ActiveJob) in
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

  private func refreshedJob(_ job: ActiveJob, scope: String) async -> ActiveJob? {
    guard
      let freshData = await transport.apiAsync("repos/\(scope)/actions/jobs/\(job.id)"),
      // JobPayload was renamed to GitHubJob in the Step 8 refactor.
      let fresh = try? decoder.decode(GitHubJob.self, from: freshData)
    else { return nil }
    let freshJob = await ISO8601DateParser.shared.makeJob(from: fresh)
    if fresh.conclusion != nil { return freshJob }
    let hasBetterSteps =
      !freshJob.steps.isEmpty
      && !freshJob.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress })
    guard hasBetterSteps else { return nil }
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
