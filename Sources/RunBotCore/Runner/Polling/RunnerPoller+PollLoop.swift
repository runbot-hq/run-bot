// RunnerPoller+PollLoop.swift
// RunBotCore
//
// Observation loop, poll-loop lifecycle (start()), adaptive-interval counters,
// and the interval-computation helper (nextPollInterval).
//
// Depends on:
//   RunnerPoller.swift          — stored properties, pollLoop, scopeStore, localRunners
//   RunnerPoller+FetchInternal  — fetch() called from the poll-loop Task

import Foundation

/// Extension housing the scope-observation loop, poll-loop lifecycle, adaptive-interval
/// counters, and interval computation for `RunnerPoller`.
extension RunnerPoller {

  // MARK: - Observation loops

  /// Starts (or restarts) the `activeScopes` observation loop.
  ///
  /// **Self-cancellation avoidance**
  /// The new `Task` is created first, then handed to `setScopeObservationTask` so
  /// the setter cancels the *previous* task rather than the one currently executing.
  func startObservingScopes() {
    let injectedStore = scopeStore
    let newTask = Task { [weak self] in
      let (stream, continuation) = AsyncStream<[String]>.makeStream()
      let observer: ObservationRelay<[String]> = await MainActor.run {
        let relay = ObservationRelay<[String]>(continuation: continuation) {
          injectedStore.activeScopes
        }
        relay.start()
        return relay
      }
      for await _ in stream {
        guard !Task.isCancelled else { break }
        log("RunnerPoller › ScopeStore.activeScopes changed — restarting fetch", category: .runner)
        await self?.startObservingScopes()
        guard !Task.isCancelled else { break }
        await self?.start()
        break
      }
      // LOAD-BEARING: keeps the ObservationRelay alive until the for-await loop above
      // exits. Without this, ARC may drop `observer` immediately after the `let`
      // binding above goes out of scope (the Task captures `self` weakly and the relay
      // is not otherwise retained), silently stopping scope-change detection.
      withExtendedLifetime(observer) {
          // Intentionally empty: body is a no-op — the call itself extends the
          // relay's lifetime past the for-await loop (see comment above).
      }
    }
    pollLoop.setScopeObservationTask(newTask)
  }

  // MARK: - Poll loop

  /// Starts (or restarts) the structured async poll loop.
  public func start() async {
    // Reset adaptive-interval counters so every restart begins from a clean state.
    // `rateLimitRemaining` is intentionally NOT reset: a stale-but-real remaining
    // value from before the restart is more useful than the Int.max sentinel.
    consecutiveIdleTicks = 0
    lastBusyRunnerCount = 0
    // Clear prevLiveJobs and completedCache so stale entries from the previous scope
    // do not trigger duplicate notifications after a scope-change restart.
    // Jobs completing in the narrow window between this clear and the next cycle's
    // API response cannot be notified — accepted pre-existing behaviour.
    prevLiveJobs = [:]
    completedCache = [:]
    let scopes = await MainActor.run { scopeStore.activeScopes }
    log("RunnerPoller › start — activeScopes=\(scopes)", category: .runner)
    if scopes.isEmpty {
      log(
        "RunnerPoller › ⚠️ start called but activeScopes is EMPTY — actions will not load",
        category: .runner)
    }
    let localCount = await MainActor.run { localRunners().count }
    log(
      "RunnerPoller › start — localRunners.count=\(localCount) at start() time", category: .runner)
    if localCount == 0 {
      log(
        "RunnerPoller › ⚠️ start — localRunners=0; installPathMap will be empty on first fetch.",
        category: .runner)
    }
    log(
      "RunnerPoller › start — previous pollTask cancelled, launching new poll task",
      category: .runner)
    // [weak self] breaks the strong actor → pollLoop → Task → actor retain cycle.
    pollLoop.setPollTask(
      Task { [weak self] in
        await self?.fetch()
        while let self, !Task.isCancelled {
          let interval = await self.nextPollInterval()
          log("RunnerPoller › poll loop — next fetch in \(Int(interval))s", category: .runner)
          do {
            try await Task.sleep(for: .seconds(interval))
          } catch is CancellationError {
            log("RunnerPoller › poll loop — CancellationError, exiting cleanly", category: .runner)
            break
          } catch {
            log("RunnerPoller › poll loop — unexpected error \(error), exiting", category: .runner)
            break
          }
          guard !Task.isCancelled else {
            log("RunnerPoller › poll loop — cancelled after sleep, exiting", category: .runner)
            break
          }
          await self.fetch()
        }
      })
  }

  // MARK: - Adaptive-interval counters

  /// Updates the two adaptive-interval counters after a successful fetch cycle.
  ///
  /// ⚠️ **Ordering constraint — call site is `RunnerPoller+ApplyResult.swift` only**:
  /// Must be called *after* `setDisplayState` so that `hasActiveWork()` evaluates
  /// the freshly-written `self.jobs` / `self.actions`.
  ///
  /// - Returns: The updated `consecutiveIdleTicks` value for log interpolation.
  @discardableResult
  func updateAdaptiveCounters(hasActiveWork: Bool, busyRunnerCount: Int) -> Int {
    if hasActiveWork {
      consecutiveIdleTicks = 0
    } else {
      consecutiveIdleTicks += 1
    }
    lastBusyRunnerCount = busyRunnerCount
    return consecutiveIdleTicks
  }

  /// Returns `true` when at least one job or action group is currently active
  /// (in-progress or queued).
  func hasActiveWork() -> Bool {
    let hasActiveJobs = jobs.contains { $0.jobStatus == .inProgress || $0.jobStatus == .queued }
    let hasActiveActions = actions.contains {
      $0.groupStatus == .inProgress || $0.groupStatus == .queued
    }
    return hasActiveJobs || hasActiveActions
  }

  // MARK: - Interval computation

  /// Computes the delay before the next poll by delegating to `PollIntervalStrategy`.
  func nextPollInterval() -> TimeInterval {
    let hasActive = hasActiveWork()
    let interval = PollIntervalStrategy.next(
      hasActiveWork: hasActive,
      consecutiveIdleTicks: consecutiveIdleTicks,
      busyRunnerCount: lastBusyRunnerCount,
      isRateLimited: isRateLimited,
      rateLimitResetDate: rateLimitResetDate,
      rateLimitRemaining: rateLimitRemaining
    )
    log(
      "RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive)"
        + " idleTick=\(consecutiveIdleTicks) busyRunners=\(lastBusyRunnerCount)"
        + " rateLimited=\(isRateLimited) rateLimitRemaining=\(rateLimitRemaining)",
      category: .runner)
    return interval
  }
}
