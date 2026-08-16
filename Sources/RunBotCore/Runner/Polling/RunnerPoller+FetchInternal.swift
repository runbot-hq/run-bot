// RunnerPoller+FetchInternal.swift
// RunBotCore
//
// One full poll cycle: fetch() (the public entry point), fetchInternal() (the
// throwing body), and deriveExtraOrgScopes() (a pre-fetch helper).
//
// Depends on:
//   RunnerPoller.swift           — stored properties, snapshots, caches
//   RunnerPoller+FetchHelpers    — fetchAllJobs(), fetchActionGroups()
//   RunnerPoller+ApplyResult     — applyFetchResult(), applyError()
//   RunnerPoller+PollBridge      — buildJobState(), buildGroupState(),
//                                  fetchAndEnrichRunners(), buildInstallPathMap()
//   RunnerPoller+PollLoop        — start() (called on runner pickup)

import Foundation
import GitHubClient

/// Extension housing one full poll cycle and its pre-fetch scope-derivation helper.
extension RunnerPoller {

  // MARK: - Fetch

  /// Performs one full poll cycle.
  func fetch() async {
    do {
      try await fetchInternal()
    } catch {
      log("RunnerPoller › fetch — ⚠️ unhandled error: \(error)", category: .runner)
      await applyError(FetchError(error))
    }
  }

  /// Inner throwing fetch body.
  private func fetchInternal() async throws {
    await clearGhRateLimit()
    let scopesSnapshot = await MainActor.run { scopeStore.activeScopes }
    log("RunnerPoller › fetch ENTER — activeScopesSnapshot=\(scopesSnapshot)", category: .runner)
    if scopesSnapshot.isEmpty {
      log("RunnerPoller › ⚠️ fetch — activeScopes snapshot is EMPTY", category: .runner)
    }
    let snapPrev = prevLiveJobs
    let snapCache = completedCache
    let snapPrevGroups = prevLiveGroups
    let snapGroupCache = actionGroupCache
    // Merge pending final groups into snapPrevGroups so they are retried on
    // this poll cycle. Also captures the retry set for `applyFetchResult`.
    let mergeResult = mergePendingFinalGroups(
      pendingFinalGroups: pendingFinalGroups,
      snapPrevGroups: snapPrevGroups,
      snapGroupCache: snapGroupCache
    )
    let localRunnersSnapshot = await MainActor.run { localRunners() }
    log(
      "RunnerPoller › fetch — localRunners.count=\(localRunnersSnapshot.count) (total; used for enrichment)",
      category: .runner)
    if localRunnersSnapshot.isEmpty {
      log(
        "RunnerPoller › ⚠️ fetch — localRunners is EMPTY; installPathMap will be empty",
        category: .runner)
    } else {
      #if DEBUG
        log(
          "RunnerPoller › fetch — localRunners=\(localRunnersSnapshot.map { "\($0.runnerName)(agentId=\(String(describing: $0.agentId)) apiId=\(String(describing: $0.apiId)))" })",
          category: .runner)
      #endif
    }
    // (#2436) Log how many runners have a resolved apiId for diagnostics.
    // The full `localRunnersSnapshot` (unfiltered) is passed to both
    // `deriveExtraOrgScopes` and `buildInstallPathMap` so that unenriched runners
    // (apiId == nil) still contribute to byName and byAgentId submaps during the
    // cold-start window. Only `byApiId` lookups require a resolved apiId, and
    // `buildInstallPathMap` handles nil apiId internally. (#2433)
    let resolvedApiIdCount = localRunnersSnapshot.filter { $0.apiId != nil }.count
    log(
      "RunnerPoller › fetch — resolvedApiIdCount=\(resolvedApiIdCount) of \(localRunnersSnapshot.count) total",
      category: .runner)
    if resolvedApiIdCount == 0 && !localRunnersSnapshot.isEmpty {
      log(
        "RunnerPoller › ⚠️ fetch — no local runners with resolved apiId; byApiId submap empty this cycle.",
        category: .runner)
    }
    // Derive extra org scopes before buildInstallPathMap so byFullKey covers
    // inferred org scopes as well as user-configured ones.
    let extraOrgScopes = deriveExtraOrgScopes(
      from: localRunnersSnapshot,
      configuredScopes: scopesSnapshot
    )
    log(
      "RunnerPoller › fetch — extraOrgScopes=\(extraOrgScopes) (\(extraOrgScopes.count) inferred from local runner gitHubUrl)",
      category: .runner)
    let allScopes = scopesSnapshot + extraOrgScopes
    let installPathMap = buildInstallPathMap(
      scopes: allScopes,
      localRunners: localRunnersSnapshot
    )
    let enrichedRunners = await fetchAndEnrichRunners(
      scopes: scopesSnapshot,
      extraOrgScopes: extraOrgScopes,
      localRunners: localRunnersSnapshot,
      installPathMap: installPathMap
    )
    let jobResult = await buildJobState(
      snapPrev: snapPrev,
      snapCache: snapCache,
      scopes: scopesSnapshot
    )
    let groupResult = await buildGroupState(
      snapPrevGroups: mergeResult.mergedPrevGroups,
      snapGroupCache: mergeResult.mergedGroupCache,
      jobCache: jobResult.newCache,
      scopes: scopesSnapshot
    )
    let didPickUp = await applyFetchResult(
      enrichedRunners: enrichedRunners,
      jobResult: jobResult,
      groupResult: groupResult,
      pendingToRetry: mergeResult.pendingToRetry
    )
    // (#2327) Restart poll loop on runner pickup so the next fetch uses a fresh
    // activeScopes snapshot. start() is called after applyFetchResult returns
    // so notification dispatch completes before the cache is cleared.
    if didPickUp { await start() }
  }

  // MARK: - Scope helpers

  /// Derives extra org scopes from local runner `gitHubUrl` values that are not
  /// already present in the user-configured scope list.
  ///
  /// Only org-scoped URLs (single path component, no "/" in the derived scope)
  /// are returned. Repo-scoped URLs are filtered out by the `!contains("/")` guard.
  /// Duplicates and scopes already in `configuredScopes` are suppressed.
  func deriveExtraOrgScopes(
    from localRunners: [RunnerModel],
    configuredScopes: [String]
  ) -> [String] {
    let configuredScopeSet = Set(configuredScopes)
    var extraSet = Set<String>()
    var extra: [String] = []
    for localRunner in localRunners {
      guard let url = localRunner.gitHubUrl,
        let derivedScope = scopeFromUrl(url),
        !derivedScope.contains("/"),
        !configuredScopeSet.contains(derivedScope),
        extraSet.insert(derivedScope).inserted
      else { continue }
      extra.append(derivedScope)
      log(
        "RunnerPoller › deriveExtraOrgScopes — derived '\(derivedScope)' from '\(localRunner.runnerName)'",
        category: .runner)
    }
    return extra
  }
// MARK: - Pending final group merging

  /// Holds the result of merging pending final groups into the poll snapshots.
  private struct PendingMergeResult {
    /// The merged snapPrevGroups with pending groups added.
    let mergedPrevGroups: [String: WorkflowActionGroup]
    /// The merged group cache with pending groups added.
    let mergedGroupCache: [String: WorkflowActionGroup]
    /// The retry set to pass to `applyFetchResult`.
    let pendingToRetry: [String: PendingFinalGroup]
  }

  /// Merges pending final groups into the snapshots for retry on the current poll cycle.
  ///
  /// Groups that have exceeded `PendingFinalGroup.maxAttempts` are abandoned. Groups
  /// that are still resolvable are merged into `snapPrevGroups` (so `buildGroupState` sees
  /// them) and `snapGroupCache` (so they remain visible in the display). The retry set
  /// is returned for the caller to pass to `applyFetchResult` so the attempt count is
  /// preserved across cycles.
  ///
  /// - Parameters:
  ///   - pendingFinalGroups: The actor's current `pendingFinalGroups` dictionary.
  ///   - snapPrevGroups: The previous live groups snapshot.
  ///   - snapGroupCache: The group cache snapshot.
  /// - Returns: A `PendingMergeResult` with the merged snapshots and retry set.
  private func mergePendingFinalGroups(
    pendingFinalGroups: [String: PendingFinalGroup],
    snapPrevGroups: [String: WorkflowActionGroup],
    snapGroupCache: [String: WorkflowActionGroup]
  ) -> PendingMergeResult {
    var mergedPrevGroups = snapPrevGroups
    var mergedGroupCache = snapGroupCache
    var pendingToRetry: [String: PendingFinalGroup] = [:]
    for (key, pending) in pendingFinalGroups {
      if snapPrevGroups[key] != nil { continue }
      if pending.attempts >= PendingFinalGroup.maxAttempts {
        log(
          "RunnerPoller › fetch — pendingFinalGroups EXCEEDED maxAttempts=\(PendingFinalGroup.maxAttempts) for key=\(key), abandoning",
          category: .runner)
        continue
      }
      let incremented = PendingFinalGroup(group: pending.group, attempts: pending.attempts + 1)
      pendingToRetry[key] = incremented
      mergedPrevGroups[key] = pending.group
      if mergedGroupCache[key] == nil, !pending.group.isCompleted {
        mergedGroupCache[key] = pending.group
      }
    }
    log(
      "RunnerPoller › fetch — pendingFinalGroups=\(pendingFinalGroups.count) toRetry=\(pendingToRetry.count)",
      category: .runner)
    return PendingMergeResult(
      mergedPrevGroups: mergedPrevGroups,
      mergedGroupCache: mergedGroupCache,
      pendingToRetry: pendingToRetry
    )
  }
}
