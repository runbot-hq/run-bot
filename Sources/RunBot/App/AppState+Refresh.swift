// AppState+Refresh.swift
// RunBot
//
// Fan-out refresh entry point. Called on panel-show (via panelShowGeneration)
// and by the manual RefreshButton in PanelMainView.

import RunBotCore

@MainActor
extension AppState {

  /// Refreshes all data pipelines: the GitHub runner poller,
  /// local runner store, and scope display names.
  ///
  /// Guards:
  /// - Bails out early if `start()` has not yet seeded `runnerStore`.
  /// - Re-entrant calls while `isRefreshing` is `true` are no-ops.
  ///
  /// Sets `isRefreshing = true` for the duration so the `RefreshButton` can
  /// disable itself during an in-flight refresh.
  ///
  /// All three pipelines are awaited sequentially. The poller's `refreshNow`
  /// coalesces concurrent callers internally, so ordering here is fine.
  /// Sequential calls sidestep Swift 6 `sending`-closure data-race diagnostics
  /// that arise when capturing actor-typed values from a @MainActor context
  /// into `withTaskGroup.addTask` closures.
  func refreshAllPipelines(reason: String) async {
    guard runnerStore != nil else {
      log("AppState > refreshAllPipelines(\(reason)) - skipped (runnerStore not yet seeded)")
      return
    }
    guard !isRefreshing else {
      log("AppState > refreshAllPipelines(\(reason)) - skipped (already refreshing)")
      return
    }

    log("AppState > refreshAllPipelines(\(reason)) - start")
    isRefreshing = true
    defer { isRefreshing = false }

    await runnerStore?.refreshNow(reason: reason)
    await localRunnerStore.refreshAsync()
    await ScopeStore.shared.refreshDisplayNames()

    log("AppState > refreshAllPipelines(\(reason)) - done")
  }
}
