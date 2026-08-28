// RunnerPoller+FetchHelpers.swift
// RunBotCore
//
// Concurrent scatter-gather helpers that fan out over all active scopes:
//   fetchAllJobs(scopes:)                          — jobs across all scopes
//   fetchActionGroups(scopes:shaKeyedCache:)        — workflow action groups
//
// Both are `internal` so RunnerPoller+PollBridge.swift can call them directly.
// Neither method touches actor-mutable state — they are pure fetch + collect.

import Foundation
import GitHubClient

/// Extension housing concurrent scope-fan-out helpers for jobs and action groups.
extension RunnerPoller {

  // MARK: - Fetch helpers

  /// Fetches all active jobs across all scopes concurrently, injecting the source scope
  /// into each job.
  ///
  /// - Parameter scopes: The scope snapshot captured by `fetchInternal` — passed in
  ///   directly to avoid re-reading `scopeStore.activeScopes` and creating a TOCTOU window.
  ///
  /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`.
  func fetchAllJobs(scopes: [String]) async -> [ActiveJob] {
    guard !scopes.isEmpty else { return [] }
    var allJobs: [ActiveJob] = []
    await withTaskGroup(of: [ActiveJob].self) { group in
      for scope in scopes {
        group.addTask {
          await fetchActiveJobs(for: scope)
            .map { $0.copying(scope: scope) }
        }
      }
      for await jobs in group { allJobs.append(contentsOf: jobs) }
    }
    log(
      "RunnerPoller › fetchAllJobs — fetched \(allJobs.count) job(s) across \(scopes.count) scope(s)",
      category: .runner)
    return allJobs
  }

  /// Fetches workflow action groups for the given scopes concurrently.
  ///
  /// - Parameters:
  ///   - scopes: The scope snapshot captured by `fetchInternal` — passed in
  ///     directly to avoid re-reading `scopeStore.activeScopes` and creating a
  ///     TOCTOU window.
  ///   - shaKeyedCache: Previously-fetched groups keyed by head SHA, forwarded to
  ///     each per-scope fetch so already-known groups are not re-enriched.
  ///
  /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`.
  func fetchActionGroups(scopes: [String], shaKeyedCache: [String: WorkflowActionGroup]) async
    -> [WorkflowActionGroup] {
    guard !scopes.isEmpty else { return [] }
    var allGroups: [WorkflowActionGroup] = []
    await withTaskGroup(of: [WorkflowActionGroup].self) { group in
      for scope in scopes {
        group.addTask { await self.actionGroupFetcher.fetch(for: scope, cache: shaKeyedCache) }
      }
      for await groups in group { allGroups.append(contentsOf: groups) }
    }
    log(
      "RunnerPoller › fetchActionGroups — fetched \(allGroups.count) group(s) across \(scopes.count) scope(s)",
      category: .runner)
    return allGroups
  }
}
