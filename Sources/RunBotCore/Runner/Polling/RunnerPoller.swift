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
/// - `preferencesStore` and `scopeStore` are `@MainActor`-isolated `Sendable` protocol
///   values; any read of their properties must happen inside `await MainActor.run { }`.
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

  /// Number of consecutive successful idle poll cycles (no active jobs or actions).
  /// Used by `PollIntervalStrategy` to compute exponential idle backoff.
  private var consecutiveIdleTicks: Int = 0
  /// Number of runners marked `busy` as of the last successful fetch cycle.
  /// Used by `PollIntervalStrategy` to select the active-interval tier.
  private var lastBusyRunnerCount: Int = 0

  /// Owns the three structured `Task` handles for the poll loop.
  /// `private` — all call sites (startObservingPreferences, startObservingScopes,
  /// start(), isolated deinit) are in this file; no extension file needs access.
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
  /// Injected preferences store. Provides `pollingInterval`.
  let preferencesStore: any AppPreferencesStoreProtocol
  /// Injected scope store. Provides `activeScopes`.
  /// `internal` (not `private`) so that extension files can read this property.
  internal let scopeStore: any ScopeStoreProtocol
  /// Shared `JSONDecoder` — reused for local decode work inside the actor.
  ///
  /// This decoder is still used by backfill helpers and other actor-local decoding.
  /// It is no longer passed into the GitHub fetcher shims, which now delegate fully
  /// to `GitHubClient` for transport, pagination, and decoding.
  let decoder = JSONDecoder()
  /// Fetcher for workflow action groups.
  let actionGroupFetcher: any WorkflowActionGroupFetcherProtocol

  // MARK: - Init

  /// Designated init for dependency injection.
  ///
  /// - Parameters:
  ///   - state: The observable read model that views and AppDelegate observe.
  ///   - preferencesStore: Provides `pollingInterval`.
  ///   - scopeStore: Provides `activeScopes`.
  ///   - localRunners: Closure returning the current local-runner snapshot on `@MainActor`.
  ///   - applyMetrics: Closure that writes enriched metrics back to the local runner store.
  ///   - actionGroupFetcher: Fetcher for workflow action groups.
  public init(
    state: RunnerState,
    preferencesStore: any AppPreferencesStoreProtocol,
    scopeStore: any ScopeStoreProtocol,
    localRunners: @escaping @MainActor @Sendable () -> [RunnerModel],
    applyMetrics: @escaping @Sendable (_ metrics: RunnerMetrics?, _ runnerId: Int, _ name: String)
      async -> Void,
    actionGroupFetcher: any WorkflowActionGroupFetcherProtocol = WorkflowActionGroupFetcher()
  ) {
    self.state = state
    self.preferencesStore = preferencesStore
    self.scopeStore = scopeStore
    self.localRunners = localRunners
    self.applyMetrics = applyMetrics
    self.actionGroupFetcher = actionGroupFetcher
    Task(name: "RunnerPoller.init: startObservingPreferences") {
      await self.startObservingPreferences()
    }
    Task(name: "RunnerPoller.init: startObservingScopes") { await self.startObservingScopes() }
  }

  // MARK: - Deinit

  /// Cancels all running Tasks owned by this actor before it is freed.
  isolated deinit {
    pollLoop.cancelAll()
  }

  // MARK: - Observation loops

  /// Starts (or restarts) the `pollingInterval` observation loop.
  private func startObservingPreferences() {
    let injectedStore = preferencesStore
    let newTask = Task { [weak self] in
      let (stream, continuation) = AsyncStream<TimeInterval>.makeStream()
      let observer: ObservationRelay<TimeInterval> = await MainActor.run {
        let relay = ObservationRelay<TimeInterval>(continuation: continuation) {
          TimeInterval(injectedStore.pollingInterval)
        }
        relay.start()
        return relay
      }
      for await newInterval in stream {
        guard !Task.isCancelled else { break }
        log(
          "RunnerPoller › pollingInterval changed to \(Int(newInterval))s — restarting poll loop",
          category: .runner)
        await self?.startObservingPreferences()
        guard !Task.isCancelled else { break }
        await self?.start()
        break
      }
      withExtendedLifetime(observer) {}
    }
    pollLoop.setIntervalObservationTask(newTask)
  }

  /// Starts (or restarts) the `activeScopes` observation loop.
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
      withExtendedLifetime(observer) {}
    }
    pollLoop.setScopeObservationTask(newTask)
  }

  // MARK: - Poll loop

  /// Starts (or restarts) the structured async poll loop.
  public func start() async {
    // Reset adaptive-interval counters so every restart begins from a clean state,
    // regardless of how deeply idle the poller was before the restart.
    consecutiveIdleTicks = 0
    lastBusyRunnerCount = 0
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
    pollLoop.setPollTask(
      Task { [weak self] in
        guard let self else { return }
        await self.fetch()
        while !Task.isCancelled {
          let interval = self.nextPollInterval()
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

  /// Returns `true` when at least one job or action group is currently active
  /// (in-progress or queued).
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
  /// read were removed in Step 4 of #2069.
  private func nextPollInterval() -> TimeInterval {
    let hasActive = hasActiveWork()
    let interval = PollIntervalStrategy.next(
      hasActiveWork: hasActive,
      consecutiveIdleTicks: consecutiveIdleTicks,
      busyRunnerCount: lastBusyRunnerCount,
      isRateLimited: isRateLimited,
      rateLimitResetDate: rateLimitResetDate,
      rateLimitRemaining: Int.max  // replace with real value at Step 9
    )
    log(
      "RunnerPoller › nextPollInterval — \(Int(interval))s hasActive=\(hasActive) idleTick=\(consecutiveIdleTicks) busyRunners=\(lastBusyRunnerCount) rateLimited=\(isRateLimited)",
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
      "RunnerPoller › fetch — localRunners.count=\(localRunnersSnapshot.count) (used for installPathMap)",
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
      snapPrevGroups: snapPrevGroups,
      snapGroupCache: snapGroupCache,
      jobCache: jobResult.newCache,
      scopes: scopesSnapshot
    )
    await applyFetchResult(
      enrichedRunners: enrichedRunners,
      jobResult: jobResult,
      groupResult: groupResult
    )
  }

  /// Derives extra org scopes from local runner `gitHubUrl` values that are not
  /// already present in the user-configured scope list.
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

  /// Fetches all active jobs across all scopes concurrently.
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
