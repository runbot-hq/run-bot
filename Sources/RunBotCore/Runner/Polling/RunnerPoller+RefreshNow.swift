// RunnerPoller+RefreshNow.swift
// RunBotCore
//
// Coalesced force-refresh entry point. Triggered by panel-show and the manual
// refresh button (AppState+Refresh.swift). All stored state is in RunnerPoller.swift.

import Foundation

extension RunnerPoller {

  /// Forces one immediate fetch outside the poll cadence.
  ///
  /// Concurrent callers are coalesced: if a refresh is already in flight, the
  /// second caller awaits the existing task and returns without starting a new one.
  /// Rapid repeat calls within `minForcedInterval` seconds are throttled and return
  /// immediately. Calls made while the GitHub rate limit is still active are skipped.
  ///
  /// - Parameter reason: A short label used in log output (e.g. `"panel-shown"`,
  ///   `"manual-refresh"`). Not used for logic.
  public func refreshNow(reason: String) async {
    // Coalesce: if a forced fetch is already running, await it and return.
    if let inFlight = refreshNowTask {
      log("RunnerPoller › refreshNow(\(reason)) — coalesced, awaiting in-flight task", category: .runner)
      await inFlight.value
      return
    }

    // Throttle: skip if the last forced refresh was too recent.
    if Date().timeIntervalSince(lastForcedRefresh) < Self.minForcedInterval {
      log("RunnerPoller › refreshNow(\(reason)) — throttled (< \(Int(Self.minForcedInterval))s since last force)", category: .runner)
      return
    }

    // Rate-limit guard: skip entirely if the window is still active.
    // `state.rateLimitResetDate` is @MainActor-isolated; hop via MainActor.run.
    let resetDate: Date? = await MainActor.run { state.rateLimitResetDate }
    if let resetDate, resetDate > Date() {
      log("RunnerPoller › refreshNow(\(reason)) — skipped (rate limited until \(resetDate))", category: .runner)
      return
    }

    log("RunnerPoller › refreshNow(\(reason)) — forced fetch starting", category: .runner)
    lastForcedRefresh = Date()

    let task = Task { await self.fetch() }
    refreshNowTask = task
    await task.value
    refreshNowTask = nil
  }
}
