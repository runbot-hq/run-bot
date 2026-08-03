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
    // (#2436) Filter to only runners with a resolved apiId — runners without one
    // cannot contribute useful entries to InstallPathMap and silently pollute it.
    // Full `localRunnersSnapshot` is still passed to `fetchAndEnrichRunners` below
    // so newly-registered runners can have their apiId resolved on the next cycle.
    let enabledLocalRunners = localRunnersSnapshot.filter { $0.apiId != nil }
    log(
      "RunnerPoller › fetch — enabledLocalRunners.count=\(enabledLocalRunners.count) (apiId resolved; used for installPathMap) of \(localRunnersSnapshot.count) total",
      category: .runner)
    if enabledLocalRunners.isEmpty && !localRunnersSnapshot.isEmpty {
      log(
        "RunnerPoller › ⚠️ fetch — no local runners with resolved apiId; installPathMap empty this cycle.",
        category: .runner)
    }
    // Derive extra org scopes before buildInstallPathMap so byFullKey covers
    // inferred org scopes as well as user-configured ones.
    let extraOrgScopes = deriveExtraOrgScopes(
      from: enabledLocalRunners,
      configuredScopes: scopesSnapshot
    )
    log(
      "RunnerPoller › fetch — extraOrgScopes=\(extraOrgScopes) (\(extraOrgScopes.count) inferred from local runner gitHubUrl)",
      category: .runner)
    let allScopes = scopesSnapshot + extraOrgScopes
    let installPathMap = buildInstallPathMap(
      scopes: allScopes,
      localRunners: enabledLocalRunners
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
      snapPrevGroups: snapPrevGroups,
      snapGroupCache: snapGroupCache,
      jobCache: jobResult.newCache,
      scopes: scopesSnapshot
    )
    let didPickUp = await applyFetchResult(
      enrichedRunners: enrichedRunners,
      jobResult: jobResult,
      groupResult: groupResult
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
}
