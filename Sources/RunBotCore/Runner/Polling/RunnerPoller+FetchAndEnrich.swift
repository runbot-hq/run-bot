// RunnerPoller+FetchAndEnrich.swift
// RunBotCore
import GitHubClient

// swiftlint:disable:next missing_docs
extension RunnerPoller {

  // MARK: - fetchAndEnrichRunners

  /// Fetches runners for the given scopes, resolves install paths, and enriches with metrics.
  ///
  /// `internal` — `fetch()` is the public entry point; this method is an implementation
  /// detail not intended for direct external calls.
  ///
  /// **Phase 0** is now handled by `deriveExtraOrgScopes(from:configuredScopes:)` in
  /// `RunnerPoller.swift`, called before `buildInstallPathMap` in `fetchInternal`. The
  /// pre-computed `extraOrgScopes` are passed in so `byFullKey` covers inferred org
  /// scopes as well as user-configured ones.
  ///
  /// **Phase 1** fans out concurrent scope fetches via `withTaskGroup`. Task completion order
  /// is non-deterministic; views sort runners for display independently.
  ///
  /// **Phase 2** enriches each busy runner with system metrics concurrently.
  ///
  /// **Install-path lookup priority** (matches the original `RunnerStore`):
  /// `byApiId ?? byAgentId ?? byFullKey ?? byName`
  /// `byFullKey` ("scope/name" composite) ranks above `byName` so runners sharing
  /// a name across different scopes resolve to the correct install path.
  ///
  /// - Parameters:
  ///   - scopes: The user-configured active scopes.
  ///   - extraOrgScopes: Inferred org scopes derived from local runner URLs (may be empty).
  ///   - localRunners: The current local-runner snapshot.
  ///   - installPathMap: Pre-built lookup maps from `buildInstallPathMap`, built with
  ///     `scopes + extraOrgScopes` so `byFullKey` covers all fetched scopes.
  func fetchAndEnrichRunners(
    scopes: [String],
    extraOrgScopes: [String],
    localRunners: [RunnerModel],
    installPathMap: InstallPathMap
  ) async -> [GitHubRunner] {
    let allScopes = scopes + extraOrgScopes
    log(
      "RunnerPoller › fetchAndEnrichRunners ENTER — scopes=\(scopes) extraOrgScopes=\(extraOrgScopes)",
      category: .runner)
    var indexed = await fetchRawRunners(allScopes: allScopes)
    indexed = await enrichBusyRunners(indexed, installPathMap: installPathMap)
    // Sequential by design: `applyMetrics` is a lightweight actor-local write
    // (updates a local runner model, no network call). The number of busy runners
    // with resolved metrics is small in practice (typically < 5). A `withTaskGroup`
    // wrapper would add task-spawn overhead without measurable benefit. Revisit only
    // if `applyMetrics` ever becomes slow (e.g. if it starts performing I/O).
    let metricsUpdates = indexed.filter { $0.runner.busy && $0.metrics != nil }
    if !metricsUpdates.isEmpty {
      for entry in metricsUpdates {
        #if DEBUG
          log(
            "RunnerPoller › fetchAndEnrichRunners — applyMetrics: \(entry.runner.name) id=\(entry.runner.id) busy=\(entry.runner.busy) metrics=\(String(describing: entry.metrics))",
            category: .runner)
        #endif
        await applyMetrics(entry.metrics, entry.runner.id, entry.runner.name)
      }
    }
    let result = indexed.map(\.runner)
    log(
      "RunnerPoller › fetchAndEnrichRunners EXIT — returning \(result.count) runner(s)",
      category: .runner)
    return result
  }

  /// Fans out concurrent scope fetches and collects all indexed runners.
  ///
  /// Extracted from `fetchAndEnrichRunners` to reduce its cyclomatic complexity (SW-R1002).
  /// Task completion order is non-deterministic; views sort runners for display independently.
  private func fetchRawRunners(allScopes: [String]) async -> [IndexedScopedRunner] {
    var indexed: [IndexedScopedRunner] = []
    await withTaskGroup(of: (String, [GitHubRunner]).self) { group in
      for scope in allScopes {
        group.addTask {
          let fetched = await fetchRunners(for: scope, decoder: self.decoder)
          return (scope, fetched)
        }
      }
      for await (scope, fetched) in group {
        indexed.append(contentsOf: fetched.map { IndexedScopedRunner(scope: scope, runner: $0) })
      }
    }
    return indexed
  }

  /// Concurrently fetches system metrics for all busy runners and applies them.
  ///
  /// Extracted from `fetchAndEnrichRunners` to reduce its cyclomatic complexity (SW-R1002).
  /// Lookup priority: `byApiId ?? byAgentId ?? byFullKey ?? byName`.
  private func enrichBusyRunners(
    _ indexed: [IndexedScopedRunner],
    installPathMap: InstallPathMap
  ) async -> [IndexedScopedRunner] {
    var indexed = indexed
    let busyIndices = indexed.indices.filter { indexed[$0].runner.busy }
    guard !busyIndices.isEmpty else { return indexed }
    let metricsResults: [(Int, RunnerMetrics?)] = await withTaskGroup(
      of: (Int, RunnerMetrics?).self
    ) { group in
      for i in busyIndices {
        let runner = indexed[i].runner
        let scope = indexed[i].scope
        let installPath =
          installPathMap.byApiId[runner.id]
          ?? installPathMap.byAgentId[runner.id]
          ?? installPathMap.byFullKey["\(scope)/\(runner.name)"]
          ?? installPathMap.byName[runner.name]
        guard let path = installPath else {
          log(
            "RunnerPoller › enrichBusyRunners — no installPath for \(runner.name) id=\(runner.id) scope=\(scope)",
            category: .runner)
          continue
        }
        group.addTask {
          let metrics = await metricsForRunner(installPath: path)
          return (i, metrics)
        }
      }
      var results: [(Int, RunnerMetrics?)] = []
      for await pair in group { results.append(pair) }
      return results
    }
    for (i, metrics) in metricsResults {
      indexed[i] = IndexedScopedRunner(scope: indexed[i].scope, runner: indexed[i].runner, metrics: metrics)
    }
    return indexed
  }
}
