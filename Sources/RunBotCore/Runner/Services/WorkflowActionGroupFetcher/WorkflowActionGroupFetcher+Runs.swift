// WorkflowActionGroupFetcher+Runs.swift
// RunBotCore

import Foundation
import GitHubClient

// MARK: - Codable helpers

/// Response envelope for the workflow runs list API endpoint.
struct ActionRunsResponse: Codable {
  /// The list of workflow runs returned by the API.
  let workflowRuns: [RunPayload]
  /// Maps the snake_case `workflow_runs` key to the camelCase Swift property.
  enum CodingKeys: String, CodingKey {
    /// Maps `workflow_runs` JSON key to `workflowRuns`.
    case workflowRuns = "workflow_runs"
  }
}

/// Composite grouping key that separates workflow runs by both `head_sha` and
/// normalised trigger event.
///
/// Commit-triggered runs (`push`, `pull_request`) share one bucket per SHA.
/// Manually dispatched runs (`workflow_dispatch`) and other non-commit events
/// each get their own bucket, even when they target the same SHA.
struct GroupKey: Hashable {
  /// The `owner/repo` scope string.
  let repo: String
  /// The full SHA of the head commit.
  let headSha: String
  /// The normalised trigger event, produced by `groupEvent(_:)` — equivalent to
  /// `WorkflowActionGroup.normalizedEvent` for the same run.
  let event: String
  /// Delegates to `WorkflowActionGroup.compositeCacheKey(repo:headSha:normalizedEvent:)`
  /// — the single canonical definition of the cache key format.
  /// `GroupKey` is private to this file and holds no `WorkflowActionGroup` instance,
  /// so the static overload is used here instead of the instance property.
  var cacheKey: String { WorkflowActionGroup.compositeCacheKey(repo: repo, headSha: headSha, normalizedEvent: event) }
}

/// - Parameter event: The raw `event` string from the GitHub runs API.
/// - Returns: A normalised bucket string used as part of `GroupKey`.
func groupEvent(_ event: String) -> String {
  switch event {
  case "push", "pull_request":
    return "commit"
  default:
    return event
  }
}

/// Minimal workflow run payload used for group construction.
///
/// `status` and `conclusion` are decoded directly as typed `JobStatus`/`JobConclusion`
/// values via their `Codable` conformances. Unknown raw strings fall through to
/// `.unknown(String)` rather than failing the decode.
struct RunPayload: Codable {
  /// The unique run identifier.
  let id: Int
  /// Stable GitHub identifier for the workflow definition.
  ///
  /// RunBot uses this as its deterministic cross-commit presentation key.
  /// This is a client-side ordering policy, not a GitHub API ordering guarantee.
  let workflowID: Int
  /// The workflow event that triggered this run (e.g. `push`, `workflow_dispatch`).
  ///
  /// A `nil` value falls back to `"commit"` at the call site via
  /// `run.event.map { groupEvent($0) } ?? "commit"`. This is equivalent
  /// to passing `"push"` through `groupEvent(_:)`, which maps to `"commit"` —
  /// the terminal bucket is always `"commit"`, not `"push"`.
  let event: String?
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
  /// The attempt number of this run. `nil` for old API responses; defaults to 1.
  let runAttempt: Int?
  /// CodingKeys mapping snake_case API fields to camelCase Swift properties.
  enum CodingKeys: String, CodingKey {
    /// Maps the `id` JSON field.
    case id
    /// Maps the `workflow_id` JSON field.
    case workflowID = "workflow_id"
    /// Maps the `event` JSON field.
    case event
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
    /// Maps the `run_attempt` JSON field.
    case runAttempt = "run_attempt"
  }
}

/// The first line of the head commit message, used as a fallback display title.
struct HeadCommit: Codable {
  /// The full commit message (only the first line is used).
  let message: String
}

/// A pull request reference attached to a workflow run.
struct PRRef: Codable {
  /// The pull request number.
  let number: Int
}

/// Response envelope for the jobs list API endpoint (`/runs/{id}/jobs`).
///
/// Replaces the deleted `JobsResponse` type from the pre-Step-8 code.
/// The GitHub API returns `{ "jobs": [ ... ] }` — this struct unwraps that envelope.
/// Decodable-only: `GitHubJob` does not conform to `Encodable`, so `Codable` would
/// fail to synthesise and is unnecessary — this struct is used only for decoding.
struct GitHubJobsWrapper: Decodable {
  /// The list of jobs returned by the API.
  let jobs: [GitHubJob]
}

// MARK: - Run-page loading helpers

/// Extension providing run-page API decoding, de-duplication and coalescing
/// helpers for ``WorkflowActionGroupFetcher``.
extension WorkflowActionGroupFetcher {

  /// Decodes workflow runs from the given API response data, appending new (unseen) runs
  /// to the `payloads` array. Duplicates are silently skipped via `seenIDs`.
  func decodeRuns(from data: Data, into payloads: inout [RunPayload], seenIDs: inout Set<Int>) {
    guard let resp = try? decoder.decode(ActionRunsResponse.self, from: data) else { return }
    for run in resp.workflowRuns {
      guard seenIDs.insert(run.id).inserted else { continue }
      payloads.append(run)
    }
  }

  /// Coalesces duplicate run IDs within one group's payload slice, keeping the entry
  /// with the most authoritative status: completed > in_progress > queued > other.
  ///
  /// A run can appear in both the in_progress and completed API pages during the brief
  /// window when GitHub marks it complete. Without coalescing, the same run enters the
  /// group twice and inflates job counts or causes incorrect status derivation.
  func coalesceRuns(_ runs: [RunPayload]) -> [RunPayload] {
    let priority: (RunPayload) -> Int = { run in
      switch run.status {
      case .completed:   return 3
      case .inProgress:  return 2
      case .queued:      return 1
      default:           return 0
      }
    }
    let coalesced = Dictionary(
      runs.map { ($0.id, $0) },
      uniquingKeysWith: { lhs, rhs in priority(lhs) >= priority(rhs) ? lhs : rhs }
    )
    // RunBot presentation policy: order by stable workflow identity so equivalent
    // workflow groups retain the same child order across commits. GitHub does not
    // document its workflow-runs response order as a stable presentation contract.
    // Run ID is only a deterministic tie-breaker for multiple runs of one workflow.
    return coalesced.values.sorted { lhs, rhs in
      if lhs.workflowID != rhs.workflowID {
        return lhs.workflowID < rhs.workflowID
      }
      return lhs.id < rhs.id
    }
  }
}
