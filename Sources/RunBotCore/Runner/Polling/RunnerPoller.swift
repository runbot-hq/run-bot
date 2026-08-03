// RunnerPoller.swift
// RunBotCore
import Foundation
import GitHubClient
import os

// MARK: - RunnerPoller

/// Swift 6 actor that owns the GitHub poll loop and all derived runner/job/action state.
///
/// **Concurrency model**
/// - The actor runs on its own executor (background thread).
/// - `scopeStore` is a `@MainActor`-isolated `Sendable` protocol value; any read of
///   its properties must happen inside `await MainActor.run { }`.
/// - After every fetch cycle, results are pushed to the injected `RunnerState` on the
///   main actor via `await MainActor.run { }`. SwiftUI's `@Observable` machinery
///   picks up the mutation automatically — no Combine `PassthroughSubject` needed.
/// - Local-runner state is read via the injected `localRunners` closure, which returns
///   a `@MainActor`-isolated snapshot without crossing into the app layer.
/// - Status-icon refresh is no longer triggered from inside the actor. `AppDelegate` wires
///   an `ObservationLoop` on `state.runners` in Step 13.
public actor RunnerPoller {

  // MARK: - State
  //
  // NOTE: Several properties below are `internal` (not `private`) solely to allow
  // extension files in separate source files to read them. All writes must go through
  // `setDisplayState(_:)` (success path) or `applyError(_:)` (failure path) in
  // RunnerPoller+ApplyResult.swift. Swift does not enforce this at the language level
  // for cross-file extensions — the invariant is documented, not mechanically enforced.

  /// Runners currently shown in the panel.
  /// Written exclusively by `applyFetchResult` (success path) and `applyError` (error path).
  private(set) var runners: [GitHubRunner] = []
  /// Jobs currently shown in the panel, including dimmed completed entries.
  /// Written exclusively by `applyFetchResult`.
  private(set) var jobs: [ActiveJob] = []
  /// Workflow action groups currently shown in the panel.
  /// Written exclusively by `applyFetchResult`.
  private(set) var actions: [WorkflowActionGroup] = []

  // MARK: ⚠️ Mutable state — write ONLY via applyFetchResult / applyError
  // (RunnerPoller+ApplyResult.swift). Swift cannot enforce this across extension
  // files; the invariant is by convention. Do not write these properties directly
  // from any other extension or call site.

  /// Live-job snapshot from the previous poll, used to detect vanished jobs.
  /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
  var prevLiveJobs: [Int: ActiveJob] = [:]
  /// Completed-job cache keyed by job ID; capped at `PollResultBuilder.jobCacheLimit`.
  /// **In-memory only** — not persisted to disk, not `Codable`. Entries are lost on
  /// app restart; this is intentional (stale cache after restart is better than
  /// persisting potentially scope-nil entries across upgrades).
  /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
  var completedCache: [Int: ActiveJob] = [:]
  /// Live-group snapshot from the previous poll, used to detect vanished groups.
  /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
  var prevLiveGroups: [String: WorkflowActionGroup] = [:]
  /// Group cache keyed by group ID; capped at `PollResultBuilder.groupCacheLimit`.
  /// Written by `applyFetchResult` (via `RunnerPoller+ApplyResult`).
  var actionGroupCache: [String: WorkflowActionGroup] = [:]
  /// Whether the GitHub API is currently rate-limiting this client.
  /// Written by `applyFetchResult` and `applyError` (via `RunnerPoller+ApplyResult`).
  private(set) var isRateLimited = false
  /// The exact moment the current rate-limit window expires, or `nil` when no
  /// rate-limit is active or the reset time is unknown.
  /// Assigned in `applyFetchResult`/`applyError` and written to `state`. periphery:ignore
  private(set) var rateLimitResetDate: Date?

  // MARK: - Adaptive poll-interval state
  //
  // Written exclusively by `applyFetchResult` (success cycles only).
  // Neither counter is updated on error cycles — both hold their last-successful-cycle
  // value through any number of consecutive failures (intentional: last known good state
  // is preferable to an unknown error state for interval selection).
  // Both are reset to 0 at the top of `start()` so every restart begins from a clean state.

  // MARK: — Adaptive-interval counters
  // All tick/busy counters are `private`; `rateLimitRemaining` is `internal` due to
  // SPM cross-file actor extension rules (see its doc-comment below).
  // The only sanctioned write path is
  // `updateAdaptiveCounters(hasActiveWork:busyRunnerCount:)` for the tick/busy
  // counters, and `applyFetchResult` for `rateLimitRemaining`.
  // `updateAdaptiveCounters` is `internal` (not `private`) for the same SPM reason;
  // the ⚠️ warning lives on that method.

  /// Consecutive successful idle poll cycles. Drives exponential idle backoff in
  /// `PollIntervalStrategy`. Reset to 0 on every `start()` and on any active fetch.
  private var consecutiveIdleTicks: Int = 0
  /// Busy-runner count from the last successful fetch. Selects the active-interval
  /// tier (Fast/Mid/Slow) in `PollIntervalStrategy`.
  private var lastBusyRunnerCount: Int = 0
  /// Calls remaining in the current GitHub API rate-limit window.
  ///
  /// Sourced from `RateLimitSnapshot.remaining` (which in turn reads the
  /// `X-RateLimit-Remaining` response header via `RateLimitActor`). Starts at
  /// `PollIntervalStrategy.rateLimitUnavailable` (`Int.max`) and is updated on
  /// every successful `applyFetchResult` cycle. The sentinel value disables the
  /// headroom-cooldown branch in `PollIntervalStrategy` until a real value is known.
  /// Not updated on error cycles — holds its last-successful-cycle value.
  ///
  /// - Note: Declared `internal` (not `private`) due to SPM cross-file actor extension
  ///   rules — the setter must be reachable from `RunnerPoller+ApplyResult.swift`.
  ///   Same constraint as `updateAdaptiveCounters`. Do not promote to `public`.
  var rateLimitRemaining: Int = PollIntervalStrategy.rateLimitUnavailable

  /// Owns the two structured `Task` handles for the poll loop.
  /// `private` — all call sites (startObservingScopes, start(), isolated deinit)
  /// are in this file; no extension file needs access.
  private let pollLoop = PollLoopCoordinator()
  /// Observable read model — the source of truth for all views and AppDelegate observers.
  public let state: RunnerState
  /// Returns the current local-runner snapshot on the `@MainActor`.
  /// Injected at init so the actor body never imports the app-layer `LocalRunnerStore`.
  let localRunners: @MainActor @Sendable () -> [RunnerModel]
  /// Writes metrics back into the local runner store.
  /// Injected at init to decouple Core from the app-layer `LocalRunnerStore` actor.
  let applyMetrics:
    @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String) async -> Void
  /// Injected preferences store. periphery:ignore
  /// No longer drives poll cadence (removed in Step 4 of #2069 — `preferencesStore.pollingInterval`
  /// replaced by `PollIntervalStrategy`). Step 10 (#2073) removed `pollingInterval` from the
  /// protocol; this property is now dead inside `RunnerPoller`. Pending removal together
  /// with its `AppState` injection site in a follow-up cleanup.
  let preferencesStore: any AppPreferencesStoreProtocol
  /// Injected scope store. Provides `activeScopes`.
  /// `internal` (not `private`) so that extension files can read this property.
  internal let scopeStore: any ScopeStoreProtocol
  /// Notification preference store used to gate `UNUserNotificationCenter` dispatch.
  /// Reads on the `@MainActor` inside `applyFetchResult` to check `shouldNotify(conclusion:)`
  /// before scheduling each notification request.
  ///
  /// `NotificationPreferences` is `@MainActor @Observable`. This property is a plain `let` on
  /// the `RunnerPoller` actor — it is never read directly from this actor context. Every access
  /// goes through `await MainActor.run { prefs.shouldNotify(conclusion:) }` which provides the
  /// required actor-hop at the call site. A future contributor must not read
  /// `notificationPreferences.notificationMode` synchronously from a non-main actor.
  ///
  /// `internal` (not `private`) so that extension files can read this property.
  internal let notificationPreferences: NotificationPreferences
  /// Shared `JSONDecoder` — reused for local decode work inside the actor.
  ///
  /// This decoder is still used by backfill helpers and other actor-local decoding.
  /// It is no longer passed into the GitHub fetcher shims, which now delegate fully
  /// to `GitHubClient` for transport, pagination, and decoding.
  let decoder = JSONDecoder()
  /// Fetcher for workflow action groups.
  let actionGroupFetcher: any WorkflowActionGroupFetcherProtocol
  /// Background ZIP prefetch queue — warms `DiskZIPCache` after each
  /// poll cycle so that `fetchStepLog` calls hit cache instead of the network.
  let zipPrefetchQueue: ZIPPrefetchQueue
  /// runIDs already handed to `zipPrefetchQueue`; prevents redundant enqueue calls
  /// across poll cycles. The queue itself is idempotent, but skipping the `await`
  /// entirely avoids actor-hop overhead on every poll tick for already-seen runs.
  /// `internal` (not `private`) solely to allow access from `RunnerPoller+ApplyResult`
  /// (SPM cross-file extension rule — see note at top of file). Write only via
  /// `applyFetchResult`.
  var prefetchedRunIDs: Set<Int> = []

  // MARK: - Init

  /// Designated init for dependency injection.
  ///
  /// - Parameters:
  ///   - state: The observable read model that views and AppDelegate observe.
  ///   - preferencesStore: Retained for other consumers; no longer drives poll cadence.
  ///   - scopeStore: Provides `activeScopes`.
  ///   - localRunners: Closure returning the current local-runner snapshot on `@MainActor`.
  ///   - applyMetrics: Closure that writes enriched metrics back to the local runner store.
  ///   - notificationPreferences: Notification preference store used to gate dispatch.
  ///     Pass `.shared` in production; pass an ephemeral instance in tests.
  ///   - actionGroupFetcher: Fetcher for workflow action groups.
  ///   - zipPrefetchQueue: Background ZIP prefetch queue. Defaults to a shared instance;
  ///     inject a stub in tests.
  public init(
    state: RunnerState,
    preferencesStore: any AppPreferencesStoreProtocol,
    scopeStore: any ScopeStoreProtocol,
    localRunners: @escaping @MainActor @Sendable () -> [RunnerModel],
    applyMetrics: @escaping @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String)
      async -> Void,
    notificationPreferences: NotificationPreferences,
    actionGroupFetcher: any WorkflowActionGroupFetcherProtocol = WorkflowActionGroupFetcher(),
    zipPrefetchQueue: ZIPPrefetchQueue? = nil
  ) {
    self.state = state
    self.preferencesStore = preferencesStore
    self.scopeStore = scopeStore
    self.localRunners = localRunners
    self.applyMetrics = applyMetrics
    self.notificationPreferences = notificationPreferences
    self.actionGroupFetcher = actionGroupFetcher
    self.zipPrefetchQueue = zipPrefetchQueue ?? ZIPPrefetchQueue(
      diskCache: DiskZIPCache(),
      transport: currentTransport
    )
    Task(name: "RunnerPoller.init: startObservingScopes") { await self.startObservingScopes() }
  }

  // MARK: - Deinit

  /// Cancels all running Tasks owned by this actor before it is freed.
  isolated deinit {
    pollLoop.cancelAll()
    let prefetchQueue = zipPrefetchQueue
    Task { await prefetchQueue.cancelAll() }
  }

  // MARK: - Observation loops

  /// Starts (or restarts) the `activeScopes` observation loop.
  ///
  /// **Self-cancellation avoidance**
  /// The new `Task` is created first, then handed to `setScopeObservationTask` so
  /// the setter cancels the *previous* task rather than the one currently executing.
  private func startObservingScopes() {
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
      withExtendedLifetime(observer) {}
    }
    pollLoop.setScopeObservationTask(newTask)
  }

  // MARK: - Poll loop

  /// Starts (or restarts) the structured async poll loop.
  public func start() async {
    // Reset adaptive-interval counters so every restart begins from a clean state,
    // regardless of how deeply idle the poller was before the restart.
    // `rateLimitRemaining` is intentionally NOT reset: a stale-but-real remaining
    // value from before the restart is more useful than the Int.max sentinel, which
    // would suppress the headroom-cooldown branch for an entire extra window.
    consecutiveIdleTicks = 0
    lastBusyRunnerCount = 0
    // Clear prevLiveJobs and completedCache so stale entries from the previous scope
    // do not trigger duplicate notifications after a scope-change restart.
    // This clear is also correct for the runner-pickup restart path (#2327): start()
    // is called from fetchInternal() after applyFetchResult() returns, so the caches
    // written by applyFetchResult are no longer needed at the point of the restart —
    // notification dispatch has already completed before applyFetchResult returned.
    // Known constraint: jobs completing in the narrow window between this clear and
    // the next cycle's API response cannot be notified, because the "was it live last
    // cycle?" baseline (prevLiveJobs) is now empty. This is a pre-existing behaviour
    // shared with the startObservingScopes() → start() scope-change path and is
    // intentionally accepted — the window is one API round-trip wide.
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
        "RunnerPoller › ⚠️ start — localRunners=0 at start time; installPathMap will be empty on first fetch.",
        category: .runner)
    }
    log(
      "RunnerPoller › start — previous pollTask cancelled, launching new poll task",
      category: .runner)
    // [weak self] is required: the Task is stored in `pollLoop` which is owned by
    // this actor, creating a strong cycle (actor → pollLoop → Task → actor).
    // `isolated deinit` only controls isolation of deinit, not when it fires —
    // ARC still requires the reference count to reach zero first, which cannot
    // happen while the Task holds a strong reference. [weak self] breaks the cycle.
    pollLoop.setPollTask(
      Task { [weak self] in
        await self?.fetch()
        while let self, !Task.isCancelled {
          // Reads counters written by the previous applyFetchResult call — intentional.
          // Counter state after fetch() completes:
          //   idle fetch  → consecutiveIdleTicks = 1 → first sleep = 60 s (idleMin * 2)
          //   active fetch → consecutiveIdleTicks = 0, lastBusyRunnerCount updated → active ladder
          //   error fetch  → counters unchanged (stay at 0 on first start) → idleMin (30 s)
          // nextPollInterval() is synchronous on the actor; `await` is needed here
          // because [weak self] means this closure runs off-actor and must hop in.
          // This is an actor hop, not an async function call; removing `await` will not compile.
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

  /// Updates the two adaptive-interval counters after a successful fetch cycle.
  ///
  /// This is the **only** sanctioned write path for `consecutiveIdleTicks` and
  /// `lastBusyRunnerCount`. Keeping the storage `private` and funnelling all writes
  /// through this method ensures no module-internal code can bypass the actor's
  /// controlled update path.
  ///
  /// ⚠️ **Ordering constraint — call site is `RunnerPoller+ApplyResult.swift` only**:
  /// Must be called *after* `setDisplayState` so that `hasActiveWork()` evaluates
  /// the freshly-written `self.jobs` / `self.actions`. Calling before `setDisplayState`
  /// would evaluate `hasActiveWork()` on stale data from the previous cycle.
  /// Do not call from other extension files or the counter order breaks.
  ///
  /// - Returns: The updated `consecutiveIdleTicks` value, so callers can use it
  ///   in log interpolation without needing direct access to the private storage.
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
  /// `internal` — read-only helper; also called from `RunnerPoller+ApplyResult.swift`
  /// to feed `updateAdaptiveCounters`. SPM file-scope rules prevent `private`/`fileprivate`
  /// for cross-file extension access within the same module.
  func hasActiveWork() -> Bool {
    let hasActiveJobs = jobs.contains { $0.jobStatus == .inProgress || $0.jobStatus == .queued }
    let hasActiveActions = actions.contains {
      $0.groupStatus == .inProgress || $0.groupStatus == .queued
    }
    return hasActiveJobs || hasActiveActions
  }

  /// Computes the delay before the next poll by delegating to `PollIntervalStrategy`.
  ///
  /// Synchronous — all inputs are actor-local properties; no `await` needed.
  /// `resolvedInterval(hasActive:baseIdle:)` and the `preferencesStore.pollingInterval`
  /// read were removed in Step 4 of #2069. `rateLimitRemaining` was wired in Step 9.
  private func nextPollInterval() -> TimeInterval {
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
      // swiftlint:disable:next line_length
      "RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) idleTick=\(consecutiveIdleTicks) busyRunners=\(lastBusyRunnerCount) rateLimited=\(isRateLimited) rateLimitRemaining=\(rateLimitRemaining)",
      category: .runner)
    return interval
  }

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
    // (#2436) Filter to only runners that have been enriched by the GitHub API at least
    // once (apiId != nil). Runners with a nil apiId have never been matched against a
    // live GitHub API runner payload and cannot contribute a useful entry to any of the
    // four InstallPathMap lookup maps — their byFullKey/byName/byAgentId entries would
    // reference install paths that can never be paired with a GitHub runner in this cycle.
    // Including them silently pollutes the maps and inflates the logged count.
    //
    // The full `localRunnersSnapshot` (unfiltered) is still passed to
    // `fetchAndEnrichRunners` below so that newly-registered runners can be matched
    // against the GitHub API and have their apiId resolved on the next enrichment cycle.
    let enabledLocalRunners = localRunnersSnapshot.filter { $0.apiId != nil }
    log(
      // swiftlint:disable:next line_length
      "RunnerPoller › fetch — enabledLocalRunners.count=\(enabledLocalRunners.count) (apiId resolved; used for installPathMap) of \(localRunnersSnapshot.count) total",
      category: .runner)
    if enabledLocalRunners.isEmpty && !localRunnersSnapshot.isEmpty {
      log(
        "RunnerPoller › ⚠️ fetch — no local runners have a resolved apiId yet; installPathMap will be empty this cycle.",
        category: .runner)
    }
    // Derive extra org scopes before buildInstallPathMap so byFullKey covers
    // inferred org scopes as well as user-configured ones. Without this,
    // installPathMap.byFullKey["\(extraOrgScope)/\(runnerName)"] always misses
    // in Phase 2 of fetchAndEnrichRunners, silently skipping metrics for runners
    // whose API id is unresolved and whose name is ambiguous across scopes.
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
    // Pass scopesSnapshot directly so fetchAllJobs and fetchActionGroups use the
    // same scope list as the rest of fetchInternal, eliminating the TOCTOU window
    // that would arise from re-reading scopeStore.activeScopes inside those methods.
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
    // (#2327) If any runner picked up work this cycle, restart the poll loop so the
    // next fetch uses a fresh activeScopes snapshot. start() is called here — after
    // applyFetchResult has fully returned — so its cache-clear runs after notification
    // dispatch is complete. No ordering constraint inside applyFetchResult is required.
    //
    // No actor-state is written after this point. start() cancels the current poll
    // Task (this Task) via pollLoop.setPollTask and spawns a new one; the old task
    // exits normally when fetchInternal returns. Swift actor exclusivity ensures the
    // new task cannot begin executing until this call stack unwinds — there is no
    // window in which both tasks mutate actor state concurrently.
    if didPickUp { await start() }
  }

  /// Derives extra org scopes from local runner `gitHubUrl` values that are not
  /// already present in the user-configured scope list.
  ///
  /// Only org-scoped URLs (single path component, no "/" in the derived scope)
  /// are returned. Repo-scoped URLs are filtered out by the `!contains("/")` guard.
  /// Duplicates and scopes already in `configuredScopes` are suppressed.
  ///
  /// Extracted from `fetchAndEnrichRunners` Phase 0 so the result is available
  /// before `buildInstallPathMap` is called, allowing `byFullKey` to cover
  /// inferred org scopes as well as user-configured ones.
  func deriveExtraOrgScopes(
    from localRunners: [RunnerModel],
    configuredScopes: [String]
  ) -> [String] {
    let configuredScopeSet = Set(configuredScopes)
    // Use a Set accumulator for O(1) dedup checks (Array.contains is O(n),
    // making the old loop O(n²) in the number of local runners). The parallel
    // `extra` array preserves insertion order for deterministic output.
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

  /// Fetches all active jobs across all scopes concurrently, injecting the source scope
  /// into each job.
  ///
  /// - Parameter scopes: The scope snapshot captured by `fetchInternal` — passed in
  ///   directly to avoid re-reading `scopeStore.activeScopes` and creating a TOCTOU
  ///   window between the snapshot used for runners/groups and the one used for jobs.
  ///
  /// `fetchActiveJobs(for:)` returns `ActiveJob` values with `scope == nil`
  /// because the GitHub Jobs API payload has no scope field. Without `.copying(scope:)`
  /// at fetch time, every concluded job entering `completedCache` has `scope == nil`.
  /// On the very next `backfillSteps` call those entries would hit the eviction branch
  /// (`scope is nil → removeValue`), causing a one-poll dimmed-job flash on every job
  /// completion — not just once after an upgrade.
  ///
  /// Note: `actionGroupFetcher.fetch(for:cache:)` is **not** used here because it contains
  /// `guard scope.contains("/") else { return [] }`, which silently drops org-scoped jobs.
  /// That guard is correct for group fetching (org-level workflow run endpoints differ),
  /// but the standalone job endpoint handles both scope kinds via `scope.apiPrefix`.
  ///
  /// Results are collected in task-completion order; no downstream consumer depends on
  /// scope-ordering of the returned array.
  ///
  /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`;
  /// not a public API. Call sites are exclusively within `RunBotCore`.
  func fetchAllJobs(scopes: [String]) async -> [ActiveJob] {
    guard !scopes.isEmpty else { return [] }
    var allJobs: [ActiveJob] = []
    await withTaskGroup(of: [ActiveJob].self) { group in
      for scope in scopes {
        group.addTask {
          // fetchActiveJobs is a free function in GitHubRunnerFetchers.swift
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

  /// Fetches workflow action groups for the given scopes concurrently, using the
  /// SHA-keyed cache.
  ///
  /// - Parameter scopes: The scope snapshot captured by `fetchInternal` — passed in
  ///   directly to avoid re-reading `scopeStore.activeScopes` and creating a TOCTOU
  ///   window between the snapshot used for runners/jobs and the one used for groups.
  ///
  /// Results are collected in task-completion order; no downstream consumer depends on
  /// scope-ordering of the returned array.
  ///
  /// `internal` — required for cross-file extension access from `RunnerPoller+PollBridge.swift`;
  /// not a public API. Call sites are exclusively within `RunBotCore`.
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

  // MARK: - Private(set) write-through

  /// Sets the actor-local display properties in a single controlled call.
  ///
  /// **Partial-update contract:** `runners`, `jobs`, and `actions` are optional.
  /// Passing `nil` means "leave unchanged" — it does **not** clear the list.
  /// `isRateLimited` and `rateLimitResetDate` are always updated on every call.
  ///
  /// `applyError` passes `nil` display lists to preserve stale data during error
  /// cycles. Do not pass `nil` intending to clear — use explicit empty arrays.
  ///
  /// - Note: nil-means-keep over enum DisplayUpdate: two call sites, same file, no safety gain.
  func setDisplayState(
    isRateLimited newIsRateLimited: Bool,
    rateLimitResetDate newResetDate: Date?,
    runners newRunners: [GitHubRunner]? = nil,
    jobs newJobs: [ActiveJob]? = nil,
    actions newActions: [WorkflowActionGroup]? = nil
  ) {
    if let newRunners { runners = newRunners }
    if let newJobs { jobs = newJobs }
    if let newActions { actions = newActions }
    isRateLimited = newIsRateLimited
    rateLimitResetDate = newResetDate
  }
}
