// RunnerPoller.swift
// RunBotCore
//
// Actor declaration, stored properties, init/deinit, and the setDisplayState
// write-through helper. All method implementations live in extension files:
//
//   RunnerPoller+PollLoop.swift      — observation loop, start(), interval math
//   RunnerPoller+FetchInternal.swift — fetch(), fetchInternal(), deriveExtraOrgScopes()
//   RunnerPoller+FetchHelpers.swift  — fetchAllJobs(), fetchActionGroups()
//   RunnerPoller+ApplyResult.swift   — applyFetchResult(), applyError()
//   RunnerPoller+PollBridge.swift    — buildJobState(), buildGroupState()

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

  // MARK: - Private(set) write-through

  /// Sets the actor-local display properties in a single controlled call.
  ///
  /// **Partial-update contract:** `runners`, `jobs`, and `actions` are optional.
  /// Passing `nil` means "leave unchanged" — it does **not** clear the list.
  /// `isRateLimited` and `rateLimitResetDate` are always updated on every call.
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
