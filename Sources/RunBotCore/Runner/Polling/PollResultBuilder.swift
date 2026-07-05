// PollResultBuilder.swift
// RunBotCore

import Foundation
import OrderedCollections

// MARK: - GroupStateDeps

/// Dependency bundle for `PollResultBuilder.buildGroupState`.
///
/// Groups the four injected closures needed by `buildGroupState` within SwiftLint's
/// `function_parameter_count` limit (≤ 6) while preserving full testability via
/// closure injection.
public struct GroupStateDeps: Sendable {
  /// Fetches live groups for every active scope.
  public let fetchGroups: @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup]
  /// Derives a scope string from a group; used as the failure-hook's second argument.
  public let scopeFromGroup: @Sendable (WorkflowActionGroup) -> String
  /// Invoked the first time a group transitions to a hook-triggering conclusion.
  public let fireFailureHook: @Sendable (WorkflowActionGroup, String) async -> Void
  /// Enriches a job list by backfilling step data from the job cache.
  public let enrichJobs: @Sendable ([ActiveJob]) async -> [ActiveJob]

  /// Creates a `GroupStateDeps` with all four injected closures.
  ///
  /// - Parameters:
  ///   - fetchGroups: Async closure that fetches live groups for every active scope.
  ///   - scopeFromGroup: Synchronous closure that derives a scope string from a group.
  ///   - fireFailureHook: Async closure invoked the first time a group transitions to
  ///     a hook-triggering conclusion (failure or cancellation).
  ///   - enrichJobs: Async closure that enriches a job list from the job cache.
  public init(
    fetchGroups: @escaping @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup],
    scopeFromGroup: @escaping @Sendable (WorkflowActionGroup) -> String,
    fireFailureHook: @escaping @Sendable (WorkflowActionGroup, String) async -> Void,
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) {
    self.fetchGroups = fetchGroups
    self.scopeFromGroup = scopeFromGroup
    self.fireFailureHook = fireFailureHook
    self.enrichJobs = enrichJobs
  }
}

// MARK: - FreezeVanishedConfig

/// Parameter bundle for `PollResultBuilder.freezeVanishedGroups`.
///
/// Packs the three snapshot/timestamp values needed by `freezeVanishedGroups`
/// so `freezeVanishedGroups` stays within SwiftLint's
/// `function_parameter_count` limit (≤ 6).
public struct FreezeVanishedConfig: Sendable {
  /// Live-group snapshot from the previous poll cycle (keyed by group ID).
  public let snapPrev: [String: WorkflowActionGroup]
  /// Group IDs present in the current live poll.
  public let liveIDs: Set<String>
  /// Timestamp used as `lastJobCompletedAt` for vanished groups that lack one.
  public let now: Date

  /// Creates a `FreezeVanishedConfig`.
  ///
  /// - Parameters:
  ///   - snapPrev: Live-group snapshot from the previous poll cycle.
  ///   - liveIDs: Group IDs present in the current live poll.
  ///   - now: Timestamp for groups whose `lastJobCompletedAt` is nil.
  public init(
    snapPrev: [String: WorkflowActionGroup],
    liveIDs: Set<String>,
    now: Date
  ) {
    self.snapPrev = snapPrev
    self.liveIDs = liveIDs
    self.now = now
  }
}

// MARK: - PollResultBuilder

/// Pure static helpers for assembling display lists and caches from poll snapshots.
///
/// All methods are static and operate only on data passed as parameters.
/// Fetch / API side-effects are injected as closures so this type is
/// independently unit-testable without a RunnerStore instance.
public enum PollResultBuilder {

  // MARK: - Cache limits

  /// Maximum number of completed jobs retained in the job cache.
  public static let jobCacheLimit = 3

  /// Maximum number of job entries shown in the panel UI (live + cached combined).
  ///
  /// Intentionally larger than `jobCacheLimit` so that live in-progress and queued
  /// jobs are never silently dropped when the cache is already full.
  /// `jobCacheLimit` controls *retention*; `jobDisplayLimit` controls *visibility*.
  public static let jobDisplayLimit = 10

  /// Maximum number of completed groups retained in the group cache.
  public static let groupCacheLimit = 30

  /// Maximum number of groups shown in the panel UI (live + cached combined).
  ///
  /// Analogous to `jobDisplayLimit` — separates *retention* from *visibility*.
  /// Prevents the panel flooding with up to `groupCacheLimit` (30) stale entries.
  public static let groupDisplayLimit = 10

  /// Maximum number of group IDs retained in the seen-IDs set.
  ///
  /// Kept much larger than `groupCacheLimit` so that the failure-hook suppression
  /// set survives well beyond the display-cache eviction horizon.
  /// Sized for ~6–7 poll cycles worth of typical group completions at once.
  /// Entries are pruned FIFO (oldest-first) when the limit is exceeded.
  public static let seenGroupIDsLimit = 200

  // MARK: - Job state

  /// Builds the job display list and updated caches from a background poll snapshot.
  ///
  /// - Parameters:
  ///   - snapPrev: Live-job snapshot from the previous poll.
  ///   - snapCache: Completed-job cache from the previous poll.
  ///   - fetchJobs: Async closure that fetches live jobs for every active scope.
  ///   - backfill: Async closure that backfills step data into a completed-job cache entry.
  public static func buildJobState(
    snapPrev: [Int: ActiveJob],
    snapCache: [Int: ActiveJob],
    fetchJobs: @Sendable () async -> [ActiveJob],
    backfill: @Sendable (inout [Int: ActiveJob]) async -> Void
  ) async -> JobPollResult {
    let allFetched: [ActiveJob] = await fetchJobs()
    // Step 8: job.jobConclusion / job.jobStatus (renamed from .conclusion / .status)
    let liveJobs: [ActiveJob] = allFetched.filter { job in
      job.jobConclusion == nil && job.jobStatus != .completed
    }
    let freshDone: [ActiveJob] = allFetched.filter { job in
      job.jobConclusion != nil || job.jobStatus == .completed
    }
    let liveIDs: Set<Int> = Set(liveJobs.map { $0.id })
    let now = Date()
    var newCache: [Int: ActiveJob] = snapCache
    applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
    for job in freshDone {
      newCache[job.id] = job.asCompleted(at: now)
    }
    trimJobCache(&newCache, limit: jobCacheLimit)
    await backfill(&newCache)
    let newPrevLive: [Int: ActiveJob] = [Int: ActiveJob](
      uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
    let display = buildJobDisplay(live: liveJobs, cache: newCache)
    // Step 8: job.jobStatus (renamed from .status)
    let inProgCount = liveJobs.filter { $0.jobStatus == .inProgress }.count
    let queuedCount = liveJobs.filter { $0.jobStatus == .queued }.count
    log(
      "PollResultBuilder › \(inProgCount) in_progress \(queuedCount) queued"
        + " | cache: \(newCache.count) | display: \(display.count)",
      category: .runner
    )
    return JobPollResult(display: display, newCache: newCache, newPrevLive: newPrevLive)
  }

  // MARK: - Group state

  /// Builds the action-group display list and updated caches from a background poll.
  ///
  /// - Parameters:
  ///   - snapPrevGroups: Live-group snapshot from the previous poll.
  ///   - snapGroupCache: Completed-group cache from the previous poll.
  ///   - deps: Injected async/sync closures (fetch, scope, hook, enrich).
  ///   - snapSeenGroupIDs: OrderedSet of group IDs that have already triggered the failure
  ///     hook in a previous poll cycle. Contains `WorkflowActionGroup.id` values.
  ///     Survives `trimGroupCache` eviction so the hook cannot re-fire for old groups.
  ///     Insertion order is preserved so `trimSeenGroupIDs` evicts the oldest entries first.
  ///     Defaults to an empty set so callers that omit this argument start with an empty set.
  ///
  /// - Important: `doneGroups` inserts into `newSeenGroupIDs` **before**
  ///   `freezeVanishedGroups` runs, so a group present in both paths fires the hook
  ///   exactly once (freezeVanishedGroups checks seenGroupIDs before firing).
  ///   Enrichment is split into two sequential sweeps — see inline comments for rationale.
  public static func buildGroupState(
    snapPrevGroups: [String: WorkflowActionGroup],
    snapGroupCache: [String: WorkflowActionGroup],
    deps: GroupStateDeps,
    snapSeenGroupIDs: OrderedSet<String> = OrderedSet()
  ) async -> GroupPollResult {
    log(
      "PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count) snapSeenGroupIDs=\(snapSeenGroupIDs.count)",
      category: .runner)
    let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
    let allFetched = await deps.fetchGroups(shaKeyedCache)
    if allFetched.isEmpty {
      log(
        "PollResultBuilder › buildGroupState — ⚠️ fetchGroups returned 0 groups; activeScopes may be empty or all scopes are unreachable",
        category: .runner)
    }
    log("PollResultBuilder › buildGroupState — allFetched=\(allFetched.count)", category: .runner)
    let liveGroups = allFetched.filter { $0.groupStatus != .completed }
    let doneGroups = allFetched.filter { $0.groupStatus == .completed }
    let liveIDs = Set(liveGroups.map { $0.id })
    let now = Date()
    var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
    // IMPORTANT: populate newSeenGroupIDs from doneGroups BEFORE calling
    // freezeVanishedGroups, so a group present in both paths fires the hook
    // exactly once (freezeVanishedGroups checks seenGroupIDs before firing).
    var newSeenGroupIDs = snapSeenGroupIDs
    await processDoneGroups(
      doneGroups,
      deps: deps,
      into: &newCache,
      seenGroupIDs: &newSeenGroupIDs
    )
    let freezeConfig = FreezeVanishedConfig(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now)
    await freezeVanishedGroups(
      config: freezeConfig,
      deps: deps,
      into: &newCache,
      seenGroupIDs: &newSeenGroupIDs
    )
    trimGroupCache(&newCache, limit: groupCacheLimit)
    trimSeenGroupIDs(&newSeenGroupIDs, limit: seenGroupIDsLimit)
    let newPrevLive = [String: WorkflowActionGroup](
      uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
    let display = buildGroupDisplay(live: liveGroups, cache: newCache)
    let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
    let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
    let loadingCount = liveGroups.filter { $0.groupStatus == .loading }.count
    log(
      "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued \(loadingCount) loading"
        + " | cache: \(newCache.count) | seenIDs: \(newSeenGroupIDs.count) | display: \(display.count)",
      category: .runner
    )
    let enriched = await enrichDisplay(display, deps: deps)
    let enrichedCache = await enrichCache(newCache, deps: deps)
    return GroupPollResult(
      display: enriched,
      newGroupCache: enrichedCache,
      newPrevLiveGroups: newPrevLive,
      newSeenGroupIDs: newSeenGroupIDs
    )
  }

  // MARK: - Job helpers

  /// Moves jobs that vanished from the live feed into the completed-job cache.
  ///
  /// A job vanishes when it disappears from the API response without transitioning
  /// through a `completed` status — most commonly a cancellation or runner disconnect.
  /// Falls back to `.neutral` (not `.cancelled`) because `.cancelled` is the conclusion
  /// GitHub sets when a user explicitly cancels via the UI; a job that silently vanishes
  /// from the feed never received that API update. Using `.neutral` avoids misattributing
  /// the cause and keeps the display consistent with GitHub's own status page.
  public static func applyVanishedJobs(
    snapPrev: [Int: ActiveJob],
    liveIDs: Set<Int>,
    now: Date,
    into cache: inout [Int: ActiveJob]
  ) {
    for (jobID, job) in snapPrev where !liveIDs.contains(jobID) {
      guard cache[jobID] == nil else { continue }
      cache[jobID] = job.asCompleted(at: now)
    }
  }

  /// Trims the job cache to at most `limit` entries, keeping the most recently completed.
  ///
  /// The sort is O(n log n), but with `jobCacheLimit = 3` this is completely
  /// irrelevant at runtime scale — do not optimise.
  public static func trimJobCache(_ cache: inout [Int: ActiveJob], limit: Int) {
    guard cache.count > limit else { return }
    // Step 8: job.completedDate (renamed from .completedAt)
    let sorted = cache.values.sorted { lhs, rhs in
      (lhs.completedDate ?? .distantPast) > (rhs.completedDate ?? .distantPast)
    }
    cache = [Int: ActiveJob](
      uniqueKeysWithValues: sorted.prefix(limit).map { job in (job.id, job) })
  }

  /// Builds the ordered job display list from live jobs and the completed cache.
  ///
  /// Display order: in-progress → queued → cached (most-recently-completed first).
  /// Live jobs are never capped by `jobCacheLimit`; the combined list is capped
  /// at `jobDisplayLimit` so the panel UI stays manageable.
  public static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
    // Step 8: job.jobStatus (renamed from .status)
    let inProgress: [ActiveJob] = live.filter { $0.jobStatus == .inProgress }
    let queued: [ActiveJob] = live.filter { $0.jobStatus == .queued }
    // Step 8: job.completedDate (renamed from .completedAt)
    let cached: [ActiveJob] = cache.values.sorted { lhs, rhs in
      (lhs.completedDate ?? .distantPast) > (rhs.completedDate ?? .distantPast)
    }
    // Use all live IDs (not just inProgress + queued) so that jobs in other
    // non-completed statuses (.waiting, .requested, .pending) also prevent
    // their stale dimmed cache entry from appearing in the display list.
    let liveJobIDs = Set(live.map { $0.id })
    var display: [ActiveJob] = []
    display.appendUpTo(jobDisplayLimit, from: inProgress)
    display.appendUpTo(jobDisplayLimit, from: queued)
    display.appendUpTo(jobDisplayLimit, from: cached) { !liveJobIDs.contains($0.id) }
    return display
  }

  // MARK: - Group helpers

  /// Returns a copy of the cache re-keyed by `headSha` instead of group ID.
  public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
    Dictionary(
      cache.values.map { ($0.headSha, $0) },
      uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
    )
  }

  /// Removes cache entries whose `headSha` appears in the freshly-fetched group list.
  ///
  /// A re-run on the same commit produces a new group ID for the same `headSha`.
  /// This method correctly evicts *all* cached groups for that SHA so the stale
  /// entries cannot ghost alongside the fresh live group.
  public static func evictFreshShas(
    from cache: [String: WorkflowActionGroup],
    freshGroups: [WorkflowActionGroup]
  ) -> [String: WorkflowActionGroup] {
    let freshShas = Set(freshGroups.map { $0.headSha })
    return cache.filter { !freshShas.contains($0.value.headSha) }
  }

  /// Freezes action groups that were live in the previous poll but have since
  /// vanished from the live feed (i.e. completed without appearing in fetchGroups).
  ///
  /// Fires `deps.fireFailureHook` for unseen groups with a hook-triggering conclusion
  /// (`isHookConclusion` — genuine failures and cancellations).
  /// Successfully completed vanished groups are cached and dimmed without an alert.
  ///
  /// The fired group's ID is appended to `seenGroupIDs` (`inout`) so the caller's
  /// `newSeenGroupIDs` reflects the vanish-path fires and the hook cannot re-fire
  /// on a subsequent poll if the group reappears in `snapPrevGroups`.
  ///
  /// - Important: Both `config.snapPrev` and the `cache` parameter are keyed by
  ///   `WorkflowActionGroup.id`, **not** by `headSha`. `config.liveIDs` must also be a
  ///   `Set<String>` of `WorkflowActionGroup.id` values for the containment check to
  ///   be correct.
  ///
  /// - Important: `buildGroupState` guarantees that `doneGroups` populates
  ///   `seenGroupIDs` **before** this function is called, so any group already in
  ///   `cache` was also already appended to `seenGroupIDs`. ID registration
  ///   (`seenGroupIDs.append`) happens before any early-exit `continue` so the
  ///   invariant "register unconditionally when unseen" holds even for groups that
  ///   hit the "already cached+dimmed" fast path. Hook-fire suppression
  ///   (`cache[groupID] == nil`) is a separate concern and must not gate the registration.
  ///
  /// - Note: This function is `public` for testability only. It has no intended
  ///   external consumers outside the `RunBotCore` module — the `inout OrderedSet`
  ///   signature is an internal implementation detail and is not considered part of
  ///   the library's public API surface.
  ///
  /// - Parameters:
  ///   - config: Snapshot, live-IDs, and timestamp bundled into a `FreezeVanishedConfig`.
  ///   - deps: Injected closures (scope derivation and failure hook).
  ///   - cache: Group cache to mutate in place.
  ///   - seenGroupIDs: Set of group IDs that have already fired the hook; mutated in place.
  public static func freezeVanishedGroups(
    config: FreezeVanishedConfig,
    deps: GroupStateDeps,
    into cache: inout [String: WorkflowActionGroup],
    seenGroupIDs: inout OrderedSet<String>
  ) async {
    log(
      "PollResultBuilder › freezeVanishedGroups — snapPrev=\(config.snapPrev.count) liveIDs=\(config.liveIDs)",
      category: .runner)
    for (groupID, group) in config.snapPrev where !config.liveIDs.contains(groupID) {
      await processVanishedGroup(
        groupID: groupID,
        group: group,
        config: config,
        deps: deps,
        into: &cache,
        seenGroupIDs: &seenGroupIDs
      )
    }
  }

  /// Trims the group cache to at most `limit` entries, keeping the most recently completed.
  ///
  /// The sort is O(n log n), but with `groupCacheLimit = 30` this is completely
  /// irrelevant at runtime scale — do not optimise.
  public static func trimGroupCache(_ cache: inout [String: WorkflowActionGroup], limit: Int) {
    guard cache.count > limit else { return }
    let sorted = cache.values.sorted { lhs, rhs in
      (lhs.lastJobCompletedAt ?? lhs.createdAt ?? .distantPast)
        > (rhs.lastJobCompletedAt ?? rhs.createdAt ?? .distantPast)
    }
    cache = [String: WorkflowActionGroup](
      uniqueKeysWithValues: sorted.prefix(limit).map { group in (group.id, group) })
  }

  /// Evicts the oldest entries from `ids` (FIFO) until `ids.count <= limit`.
  ///
  /// Because `ids` is an `OrderedSet`, the elements with the lowest indices
  /// (inserted earliest) are removed first, giving true FIFO eviction.
  ///
  /// - Parameters:
  ///   - ids: The seen-group-IDs set to trim in place.
  ///   - limit: Maximum number of entries to retain.
  public static func trimSeenGroupIDs(_ ids: inout OrderedSet<String>, limit: Int) {
    guard ids.count > limit else { return }
    let excess = ids.count - limit
    ids.removeSubrange(0..<excess)
  }

  /// Builds the ordered group display list from live groups and the completed cache.
  ///
  /// Display order: in-progress → loading → queued → cached (most-recently-completed first).
  /// Capped at `groupDisplayLimit` — analogous to `jobDisplayLimit` for jobs.
  public static func buildGroupDisplay(
    live: [WorkflowActionGroup],
    cache: [String: WorkflowActionGroup]
  ) -> [WorkflowActionGroup] {
    let inProgress = live.filter { $0.groupStatus == .inProgress }
    let loading = live.filter { $0.groupStatus == .loading }
    let queued = live.filter { $0.groupStatus == .queued }
    // Use all live IDs (not just inProgress + queued) so that groups in other
    // non-completed statuses (.loading, .waiting, .requested, etc.) also prevent
    // their stale dimmed cache entry from appearing alongside the live entry.
    // Mirrors the identical reasoning in buildJobDisplay.
    let liveGroupIDs = Set(live.map { $0.id })
    let cached = cache.values.sorted { lhs, rhs in
      (lhs.lastJobCompletedAt ?? lhs.createdAt ?? .distantPast)
        > (rhs.lastJobCompletedAt ?? rhs.createdAt ?? .distantPast)
    }
    var display: [WorkflowActionGroup] = []
    display.appendUpTo(groupDisplayLimit, from: inProgress)
    display.appendUpTo(groupDisplayLimit, from: loading)
    display.appendUpTo(groupDisplayLimit, from: queued)
    display.appendUpTo(groupDisplayLimit, from: cached) { !liveGroupIDs.contains($0.id) }
    return display
  }

  // MARK: - Private helpers

  /// Processes the `doneGroups` list: fires the failure hook for newly-seen groups
  /// with a hook-triggering conclusion, then writes each group into the cache (dimmed).
  ///
  /// Must be called **before** `freezeVanishedGroups` so that `seenGroupIDs` is
  /// fully populated before the vanish-path runs its own hook-fire check.
  ///
  /// - Parameters:
  ///   - doneGroups: Groups whose `groupStatus == .completed` in the current poll.
  ///   - deps: Injected closures (scope derivation, hook, enrich).
  ///   - cache: Group cache to mutate in place (each done group is written dimmed).
  ///   - seenGroupIDs: Hook-suppression set to mutate in place.
  private static func processDoneGroups(
    _ doneGroups: [WorkflowActionGroup],
    deps: GroupStateDeps,
    into cache: inout [String: WorkflowActionGroup],
    seenGroupIDs: inout OrderedSet<String>
  ) async {
    for group in doneGroups {
      let isNew = !seenGroupIDs.contains(group.id)
      let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(
        separator: ", ")
      log(
        "PollResultBuilder › doneGroups — groupID=\(group.id) isNew=\(isNew) runs=[\(runSummary)]",
        category: .runner)
      if isNew {
        let scope = deps.scopeFromGroup(group)
        log(
          "PollResultBuilder › doneGroups — groupID=\(group.id) isNew=true → scope=\(scope)",
          category: .runner)
        let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
        if shouldFire {
          await deps.fireFailureHook(group, scope)
        }
        // Append for ALL hook-eligible conclusions (failure, cancelled) AND
        // for non-hook conclusions (success, skipped). Non-hook groups must
        // also be registered so that freezeVanishedGroups cannot ghost-fire
        // them later if stale state lingers in snapPrevGroups.
        // Re-runs on the same SHA produce a new group ID (evictFreshShas
        // resets the cache entry), so this append never pre-suppresses a
        // fresh run.
        seenGroupIDs.append(group.id)
      }
      cache[group.id] = group.copying(isDimmed: true)
    }
  }

  /// Enriches the display array by running `deps.enrichJobs` over each group's jobs
  /// concurrently via a `withTaskGroup`, preserving the original display sort order.
  ///
  /// Keyed by `Int` (array index) so the order produced by `buildGroupDisplay` is
  /// faithfully restored after `withTaskGroup` yields results in completion order.
  private static func enrichDisplay(
    _ display: [WorkflowActionGroup],
    deps: GroupStateDeps
  ) async -> [WorkflowActionGroup] {
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
      for (idx, actionGroup) in display.enumerated() {
        group.addTask { (idx, actionGroup.withJobs(await deps.enrichJobs(actionGroup.jobs))) }
      }
      var out: [(Int, WorkflowActionGroup)] = []
      for await pair in group { out.append(pair) }
      return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
  }

  /// Enriches the group cache by running `deps.enrichJobs` over each cached group's
  /// jobs concurrently via a `withTaskGroup`.
  ///
  /// Keyed by `String` (group ID) because `newCache` is a dictionary and its
  /// semantic identity IS the group ID. Kept separate from `enrichDisplay` because
  /// the key types differ (Int vs String) and the source collections differ
  /// (display array vs cache dict).
  private static func enrichCache(
    _ cache: [String: WorkflowActionGroup],
    deps: GroupStateDeps
  ) async -> [String: WorkflowActionGroup] {
    await withTaskGroup(of: (String, WorkflowActionGroup).self) { group in
      for (key, actionGroup) in cache {
        group.addTask { (key, actionGroup.withJobs(await deps.enrichJobs(actionGroup.jobs))) }
      }
      var out: [String: WorkflowActionGroup] = [:]
      for await (key, actionGroup) in group { out[key] = actionGroup }
      return out
    }
  }

  /// Handles a single vanished group inside `freezeVanishedGroups`.
  ///
  /// Registers the group ID unconditionally in `seenGroupIDs`, applies the
  /// fast-path skip for already-cached-and-dimmed groups, fires the hook when
  /// appropriate, and writes the frozen entry into `cache`.
  ///
  /// `deps.scopeFromGroup` and `deps.fireFailureHook` are used in place of loose
  /// closure parameters so this function stays within SwiftLint's
  /// `function_parameter_count` limit (≤ 6).
  private static func processVanishedGroup(
    groupID: String,
    group: WorkflowActionGroup,
    config: FreezeVanishedConfig,
    deps: GroupStateDeps,
    into cache: inout [String: WorkflowActionGroup],
    seenGroupIDs: inout OrderedSet<String>
  ) async {
    log(
      "PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id) inCache=\(cache[groupID] != nil)",
      category: .runner)
    // Register the ID unconditionally before any early-exit so the invariant holds:
    // a group that hits the cached+dimmed fast path below must still be marked seen,
    // otherwise a re-run (which resets jobs.count) could re-arm the hook.
    // OrderedSet.append is a no-op for duplicates, so calling it unconditionally
    // is always safe even when doneGroups already registered this ID first.
    let isUnseen = !seenGroupIDs.contains(groupID)
    if isUnseen { seenGroupIDs.append(groupID) }
    // Fast path: group is already cached and dimmed with at least as many jobs
    // as the previous snapshot — no cache update needed. Note: seenGroupIDs was
    // already mutated above, so the hook-suppression invariant holds even for
    // groups that exit here. The cache write is skipped; the ID registration is not.
    if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
      log(
        "PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) already cached+dimmed, skipping",
        category: .runner)
      return
    }
    // Hook-fire gate: requires both isUnseen AND cache[groupID] == nil.
    // isUnseen guards against re-fire after seenGroupIDs registration above.
    // cache[groupID] == nil guards against re-fire for groups already written
    // to cache by a previous iteration or by the doneGroups path.
    if isUnseen && cache[groupID] == nil {
      let scope = deps.scopeFromGroup(group)
      let shouldFire = group.runs.contains { $0.conclusion?.isHookConclusion == true }
      if shouldFire {
        log(
          "PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) unseen+hookConclusion → fireFailureHook scope=\(scope)",
          category: .runner)
        await deps.fireFailureHook(group, scope)
      }
    }
    if group.lastJobCompletedAt == nil {
      cache[groupID] = group.copying(isDimmed: true, settingCompletedAt: config.now)
    } else {
      cache[groupID] = group.copying(isDimmed: true)
    }
  }
}

// MARK: - Array fill helper

/// Sequence-filling helpers used by `PollResultBuilder` to top up display arrays.
private extension Array {
  /// Appends elements from `source` until `self.count` reaches `limit`.
  ///
  /// Elements are appended in source order. An optional predicate can skip
  /// individual elements (e.g. cached groups that are already live) without
  /// breaking the "fill until full" semantics.
  ///
  /// - Note: `internal` (not `private`) because Swift does not allow `private`
  ///   on extensions that are not in the same file as the primary type declaration.
  ///   `Array` is defined in the standard library, so `private` here would mean
  ///   file-private — invisible to `PollResultBuilder`'s callers within the same
  ///   module but also invisible across files. `internal` is the narrowest access
  ///   level that lets `PollResultBuilder` (and its test targets) call this method
  ///   without leaking it as `public` API. It is **not** intended for use outside
  ///   the polling pipeline; treat it as an implementation detail of
  ///   `buildJobDisplay` and `buildGroupDisplay`.
  fileprivate mutating func appendUpTo<S>(
    _ limit: Int,
    from source: S,
    where shouldAppend: (S.Element) -> Bool = { _ in true }
  ) where S: Sequence, S.Element == Element {
    guard count < limit else { return }
    for element in source where count < limit && shouldAppend(element) {
      append(element)
    }
  }
}
