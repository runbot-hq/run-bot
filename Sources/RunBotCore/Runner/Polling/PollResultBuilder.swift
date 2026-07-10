// PollResultBuilder.swift
// RunBotCore

import Foundation

// MARK: - GroupStateDeps

/// Dependency bundle for `PollResultBuilder.buildGroupState`.
///
/// Groups the two injected closures needed by `buildGroupState` within SwiftLint's
/// `function_parameter_count` limit (≤ 6) while preserving full testability via
/// closure injection.
public struct GroupStateDeps: Sendable {
  /// Fetches live groups for every active scope.
  public let fetchGroups: @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup]
  /// Enriches a job list by backfilling step data from the job cache.
  public let enrichJobs: @Sendable ([ActiveJob]) async -> [ActiveJob]

  /// Creates a `GroupStateDeps` with the two injected closures.
  ///
  /// - Parameters:
  ///   - fetchGroups: Async closure that fetches live groups for every active scope.
  ///   - enrichJobs: Async closure that enriches a job list from the job cache.
  public init(
    fetchGroups: @escaping @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) {
    self.fetchGroups = fetchGroups
    self.enrichJobs = enrichJobs
  }
}

// MARK: - FreezeVanishedConfig

/// Parameter bundle for `PollResultBuilder.freezeVanishedGroups`.
///
/// Packs the three snapshot/timestamp values needed by `freezeVanishedGroups`
/// so `freezeVanishedGroups` stays within SwiftLint's
/// `function_parameter_count` limit (≤ 6).
struct FreezeVanishedConfig: Sendable {
  /// Live-group snapshot from the previous poll cycle (keyed by group ID).
  let snapPrev: [String: WorkflowActionGroup]
  /// Group IDs present in the current live poll.
  let liveIDs: Set<String>
  /// Timestamp used as `lastJobCompletedAt` for vanished groups that lack one.
  let now: Date
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
  ///   - deps: Injected async/sync closures (fetch, enrich).
  ///
  /// Enrichment is split into two sequential sweeps — see inline comments for rationale.
  public static func buildGroupState(
    snapPrevGroups: [String: WorkflowActionGroup],
    snapGroupCache: [String: WorkflowActionGroup],
    deps: GroupStateDeps
  ) async -> GroupPollResult {
    log(
      "PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count)",
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
    // Dim and cache every completed group that came back from fetchGroups.
    // `freezeVanishedGroups` (below) handles the complementary case: groups that
    // were live last poll but are now absent from the feed entirely.
    //
    // `wasNotCached`: diagnostic only — true when this group was absent from the
    // cache after SHA-eviction. This is intentionally a within-poll cache check,
    // not a cross-poll novelty signal. Cross-poll deduplication (seenGroupIDs)
    // was removed along with the failure-hook feature and is not coming back.
    for group in doneGroups {
      let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
      let wasNotCached = newCache[group.id] == nil
      log(
        "PollResultBuilder › doneGroups — groupID=\(group.id) wasNotCached=\(wasNotCached) runs=[\(runSummary)]",
        category: .runner)
      newCache[group.id] = group.copying(isDimmed: true)
    }
    let freezeConfig = FreezeVanishedConfig(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now)
    freezeVanishedGroups(config: freezeConfig, into: &newCache)
    trimGroupCache(&newCache, limit: groupCacheLimit)
    let newPrevLive = [String: WorkflowActionGroup](
      uniqueKeysWithValues: liveGroups.map { ($0.id, $0) })
    let display = buildGroupDisplay(live: liveGroups, cache: newCache)
    let inProgCount = liveGroups.filter { $0.groupStatus == .inProgress }.count
    let queuedCount = liveGroups.filter { $0.groupStatus == .queued }.count
    let loadingCount = liveGroups.filter { $0.groupStatus == .loading }.count
    log(
      "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued \(loadingCount) loading"
        + " | cache: \(newCache.count) | display: \(display.count)",
      category: .runner
    )
    let enriched = await enrichDisplay(display, deps: deps)
    let enrichedCache = await enrichCache(newCache, deps: deps)
    return GroupPollResult(
      display: enriched,
      newGroupCache: enrichedCache,
      newPrevLiveGroups: newPrevLive
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
  /// Vanished groups are written into `cache` dimmed. Both `config.snapPrev` and
  /// `cache` are keyed by `WorkflowActionGroup.id`; `config.liveIDs` must also be
  /// a `Set<String>` of `WorkflowActionGroup.id` values for the containment check
  /// to be correct.
  ///
  /// `internal` (not `public`): exercised indirectly through `buildGroupState` in tests;
  /// no direct external callers exist outside `RunBotCore`.
  ///
  /// - Parameters:
  ///   - config: Snapshot, live-IDs, and timestamp bundled into a `FreezeVanishedConfig`.
  ///   - cache: Group cache to mutate in place.
  static func freezeVanishedGroups(
    config: FreezeVanishedConfig,
    into cache: inout [String: WorkflowActionGroup]
  ) {
    log(
      "PollResultBuilder › freezeVanishedGroups — snapPrev=\(config.snapPrev.count) liveIDs=\(config.liveIDs)",
      category: .runner)
    for (groupID, group) in config.snapPrev where !config.liveIDs.contains(groupID) {
      processVanishedGroup(groupID: groupID, group: group, config: config, into: &cache)
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
  /// Fast-path skips groups already cached and dimmed with at least as many jobs
  /// as the previous snapshot. Otherwise writes the frozen entry into `cache`.
  private static func processVanishedGroup(
    groupID: String,
    group: WorkflowActionGroup,
    config: FreezeVanishedConfig,
    into cache: inout [String: WorkflowActionGroup]
  ) {
    if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
      log(
        "PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) skipped (already cached+dimmed, jobs=\(existing.jobs.count)≥\(group.jobs.count))",
        category: .runner)
      return
    }
    // `existsUndimmed=true` means a cache entry exists but failed the fast-path guard —
    // either it is not yet dimmed, or its job count is smaller than the snapshot.
    // This is distinct from general cache presence: the entry will be overwritten below.
    log(
      "PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id) existsUndimmed=\(cache[groupID] != nil) jobs=\(group.jobs.count)",
      category: .runner)
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
