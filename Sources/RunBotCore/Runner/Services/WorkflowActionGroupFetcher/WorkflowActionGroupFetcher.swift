// WorkflowActionGroupFetcher.swift
// RunBotCore
import Foundation
import GitHubClient
import os

// MARK: - WorkflowActionGroupFetcher

/// Fetches and groups workflow action groups for one or more repo scopes.
///
/// Accepts any `GitHubTransportProtocol` conformer so the hot polling path
/// is testable without live network access. Production callers use the
/// default `currentTransport`; tests inject a stub via `withTransport(_:operation:)`.
///
/// - SeeAlso: ``GitHubTransportProtocol``
public struct WorkflowActionGroupFetcher: Sendable, WorkflowActionGroupFetcherProtocol {

  /// The transport used for all GitHub API calls made by this fetcher.
  let transport: any GitHubTransportProtocol

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
  let decoder = JSONDecoder()

  /// Creates a fetcher backed by the given transport.
  ///
  /// - Parameter transport: Defaults to `currentTransport` — the live `@TaskLocal`
  ///   read path wired by `GitHubClient.init`. Tests can override via
  ///   `withTransport(_:operation:)` without touching any global.
  public init(transport: any GitHubTransportProtocol = currentTransport) {
    self.transport = transport
  }

  // MARK: - Fetch + Group

  /// Fetches active workflow runs for a repo scope, groups them by composite key
  /// `(head_sha, normalised_event)`, enriches each group with its flattened job list,
  /// and returns groups sorted: in-progress first, then queued, then completed —
  /// newest first within each tier.
  ///
  /// All three status fetches (in_progress, queued, completed) run concurrently.
  /// Per-run job fetches within each group also run concurrently.
  /// Date parsing goes through `ISO8601DateParser.shared` — one actor, one formatter.
  ///
  /// - Note: `@concurrent` is applied only to this public entry point so that
  ///   callers on an actor-bound context (e.g. `RunnerPoller`'s custom actor executor) hop
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

    var byGroupKey: [GroupKey: [RunPayload]] = [:]
    for run in runPayloads {
      let key = GroupKey(repo: scope, headSha: run.headSha, event: run.event.map { groupEvent($0) } ?? "commit")
      byGroupKey[key, default: []].append(run)
    }

    // Phase 2: fetch recently completed runs and merge into ALL groups.
    if let data = cData {
      decodeRuns(from: data, into: &runPayloads, seenIDs: &seenIDs)
      // Re-constructing byGroupKey entirely is safer and cleaner than mutating the old dict
      byGroupKey.removeAll(keepingCapacity: true)
      for run in runPayloads {
        let key = GroupKey(repo: scope, headSha: run.headSha, event: run.event.map { groupEvent($0) } ?? "commit")
        byGroupKey[key, default: []].append(run)
      }
    }

    // Coalesce any run that appeared in both in_progress and completed payloads,
    // preferring the most authoritative status (completed > in_progress > queued).
    byGroupKey = byGroupKey.mapValues(coalesceRuns)

    // Build groups concurrently — index-keyed to preserve insertion order.
    let groupEntries = Array(byGroupKey)
    var groups = Array(repeating: WorkflowActionGroup?.none, count: groupEntries.count)
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
      for (i, (groupKey, groupRuns)) in groupEntries.enumerated() {
        group.addTask {
          await self.buildActionGroup(
            index: i, groupKey: groupKey, groupRuns: groupRuns, scope: scope, cache: cache)
        }
      }
      for await (i, actionGroup) in group { groups[i] = actionGroup }
    }

    let result = groups.compactMap { $0 }
    log("fetchActionGroups -- \(result.count) group(s) for \(scope)", category: .runner)
    return sort(groups: result)
  }
}
