// PollResultBuilder.swift
// RunBotCore

import Foundation

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
    let liveJobs: [ActiveJob] = allFetched.filter { job in
      job.jobConclusion == nil && job.jobStatus != .completed
    }
    let freshDone: [ActiveJob] = allFetched.filter { job in
      job.jobConclusion != nil || job.jobStatus == .completed
    }
    let liveIDs: Set<Int> = Set(liveJobs.map { $0.id })
    let now = Date()
    var newCache: [Int: ActiveJob] = snapCache
    // Operation order is intentional:
    // 1. applyVanishedJobs: promotes jobs that disappeared from the live feed into
    //    the cache as stubs (guarded by cache[jobID] == nil, so safe to run first).
    // 2. freshDone loop: writes authoritative completed entries from the API response.
    //    If a job appears in both snapPrev (vanished) and freshDone (came back completed
    //    in the same poll), the freshDone entry wins — the API is authoritative and the
    //    vanished stub written in step 1 is silently replaced. This is correct behaviour.
    // 3. trimJobCache + backfill: operate on the fully merged cache produced by 1 & 2.
    //    backfill must run last so it enriches the complete set of cache entries.
    applyVanishedJobs(snapPrev: snapPrev, liveIDs: liveIDs, now: now, into: &newCache)
    for job in freshDone {
      newCache[job.id] = job.asCompleted(at: now)
    }
    trimJobCache(&newCache, limit: jobCacheLimit)
    await backfill(&newCache)
    let newPrevLive: [Int: ActiveJob] = [Int: ActiveJob](
      uniqueKeysWithValues: liveJobs.map { ($0.id, $0) })
    let display = buildJobDisplay(live: liveJobs, cache: newCache)
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
  ///   - fetchGroups: Async closure that fetches live groups for every active scope.
  ///   - enrichJobs: Async closure that enriches a job list from the job cache.
  ///
  /// Both closures are `@escaping` because they are forwarded into `withTaskGroup.addTask`
  /// (an escaping context) inside `enrichDisplay` and `enrichCache`. Removing `@escaping`
  /// here will produce a compiler error in those private helpers. By contrast,
  /// `buildJobState`'s closures are non-escaping because they are called directly
  /// and never forwarded into an escaping context — the asymmetry is intentional.
  ///
  /// Enrichment runs as two separate sweeps — once over the display array and once over
  /// the full cache — because they are distinct collections that cannot be derived from
  /// each other. The display array is a capped, ordered subset (up to `groupDisplayLimit`
  /// entries, sorted by status then recency). The cache is the complete, unordered
  /// dictionary of all retained groups. Enriching only the display and rebuilding the
  /// cache from it would silently drop cache entries that fall outside the display cap.
  public static func buildGroupState(
    snapPrevGroups: [String: WorkflowActionGroup],
    snapGroupCache: [String: WorkflowActionGroup],
    fetchGroups: @escaping @Sendable ([String: WorkflowActionGroup]) async -> [WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob],
    enqueueZIP: @Sendable (Int, String, Bool) async -> Void = { _, _, _ in }
  ) async -> GroupPollResult {
    log(
      "PollResultBuilder › buildGroupState — snapPrevGroups=\(snapPrevGroups.count) snapGroupCache=\(snapGroupCache.count)",
      category: .runner)
    let shaKeyedCache = makeShaKeyedCache(snapGroupCache)
    let allFetched = await fetchGroups(shaKeyedCache)
    if allFetched.isEmpty {
      log(
        "PollResultBuilder › buildGroupState — ⚠️ fetchGroups returned 0 groups; activeScopes may be empty or all scopes are unreachable",
        category: .runner)
    }
    log("PollResultBuilder › buildGroupState — allFetched=\(allFetched.count)", category: .runner)
    let liveGroups = allFetched.filter { $0.groupStatus != .completed }
    let doneGroups = allFetched.filter { $0.groupStatus == .completed }
    // liveIDs intentionally excludes completed groups (doneGroups). Groups in doneGroups
    // are written into newCache as isDimmed below. If one of those completed groups also
    // appears in snapPrevGroups, freezeVanishedGroups will encounter it — but its
    // fast-path guard (existing.isDimmed && jobs >= snapshot) will skip it cleanly.
    let liveIDs = Set(liveGroups.map { $0.id })
    let now = Date()
    // NOTE: eviction must happen before doneGroups are written into newCache.
    // Order is load-bearing: evictFreshShas sees the pre-completion cache state.
    // Reversing these two operations would incorrectly evict entries just completed.
    var newCache = evictFreshShas(from: snapGroupCache, freshGroups: allFetched)
    // Dim and cache every completed group that came back from fetchGroups.
    // `freezeVanishedGroups` (below) handles the complementary case: groups that
    // were live last poll but are now absent from the feed entirely.
    for group in doneGroups {
      let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
      log(
        "PollResultBuilder › doneGroups — groupID=\(group.id) runs=[\(runSummary)]",
        category: .runner)
      // Enqueue a ZIP prefetch for each workflow run in this completed group.
      // `DiskZIPCache.get(runID:)` inside `enqueue` prevents re-downloading on
      // subsequent polls, so it is safe to call every cycle.
      for run in group.runs {
        await enqueueZIP(run.id, group.repo, true)
      }
      newCache[group.id] = group.copying(isDimmed: true)
    }
    freezeVanishedGroups(snapPrev: snapPrevGroups, liveIDs: liveIDs, now: now, into: &newCache)
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
    let enriched = await enrichDisplay(display, enrichJobs: enrichJobs)
    // Intentionally enriches the full newCache, not just live groups. The cache feeds
    // the next poll's display list; dimmed/completed groups that carry stale job data
    // would surface as incorrect enrichment on the following cycle if skipped here.
    let enrichedCache = await enrichCache(newCache, enrichJobs: enrichJobs)
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
  ///
  /// Existing cache entries are intentionally skipped (`guard cache[jobID] == nil`).
  /// By the time this function runs, `backfill` may have already enriched those entries
  /// with step-level data from a previous poll cycle. Overwriting them here would silently
  /// discard that enrichment and replace a detailed entry with a bare vanished-job stub.
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
    let sorted = cache.values.sorted { lhs, rhs in
      (lhs.completedDate ?? .distantPast) > (rhs.completedDate ?? .distantPast)
    }
    cache = [Int: ActiveJob](
      uniqueKeysWithValues: sorted.prefix(limit).map { job in (job.id, job) })
  }

  /// Builds the ordered job display list from live jobs and the completed cache.
  ///
  /// Display order: in-progress -> queued -> cached (most-recently-completed first).
  /// Live jobs are never capped by `jobCacheLimit`; the combined list is capped
  /// at `jobDisplayLimit` so the panel UI stays manageable.
  public static func buildJobDisplay(live: [ActiveJob], cache: [Int: ActiveJob]) -> [ActiveJob] {
    let inProgress: [ActiveJob] = live.filter { $0.jobStatus == .inProgress }
    let queued: [ActiveJob] = live.filter { $0.jobStatus == .queued }
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
  ///
  /// Used to pass a SHA-indexed snapshot to `fetchGroups` so the fetcher can detect
  /// re-runs on the same commit (same `headSha`, new group ID) and avoid returning
  /// stale cached data for them.
  ///
  /// When two cache entries share the same composite key (possible if a re-run was cached
  /// before the original was evicted), the tie-break keeps the entry with the larger
  /// group ID. Group IDs are monotonically increasing — a higher ID means a newer run
  /// — so this retains the most recent run's cache entry for each key.
  ///
  /// The composite key is `WorkflowActionGroup.compositeCacheKey` (`"headSha:normalizedEvent"`)
  /// — defined on the model so producer (`PollResultBuilder`) and consumer
  /// (`WorkflowActionGroupFetcher`) share a single canonical format and cannot drift.
  /// A pure `headSha` key would cause 100% cache misses for completed runs when
  /// the event differs (regression from #2434).
  public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
    Dictionary(
      cache.values.map { ($0.compositeCacheKey, $0) },
      uniquingKeysWith: { lhs, rhs in lhs.id > rhs.id ? lhs : rhs }
    )
  }

  /// Removes cache entries whose composite identity (`headSha:normalizedEvent`) appears
  /// in the freshly-fetched group list.
  ///
  /// - Parameter cache: The **ID-keyed** group cache (`snapGroupCache`). Each entry's
  ///   composite identity is derived from its *value* fields rather than its key, because
  ///   the cache is keyed by group ID, not by `"headSha:normalizedEvent"`.
  /// - Parameter freshGroups: The groups returned by the current live fetch.
  ///
  /// A re-run on the same commit produces a new group ID for the same `headSha`.
  /// Evicting by composite identity (not bare `headSha`) ensures that a fresh `push`
  /// group does not accidentally evict a cached `workflow_dispatch` group that shares
  /// the same SHA but belongs to a different event bucket.
  ///
  /// Note: `$0.value.compositeCacheKey` is used (not `$0.key`) because this dict is
  /// ID-keyed — `$0.key` is a group ID string, not a composite key. `compositeCacheKey`
  /// is defined on `WorkflowActionGroup` and propagated by all mutation paths
  /// (`withJobs`, `copying`), so the value-based lookup is safe.
  public static func evictFreshShas(
    from cache: [String: WorkflowActionGroup],
    freshGroups: [WorkflowActionGroup]
  ) -> [String: WorkflowActionGroup] {
    // NOTE: This cache is ID-keyed (group.id), not composite-keyed.
    // $0.key is a group ID string — using $0.key here would silently skip all evictions.
    // We derive the composite key from the value instead, which is correct for this dict.
    let freshKeys = Set(freshGroups.map { $0.compositeCacheKey })
    return cache.filter { !freshKeys.contains($0.value.compositeCacheKey) }
  }

  /// Freezes action groups that were live in the previous poll but have since
  /// vanished from the live feed (i.e. completed without appearing in fetchGroups).
  ///
  /// Vanished groups are written into `cache` dimmed. Both `snapPrev` and `cache`
  /// are keyed by `WorkflowActionGroup.id`; `liveIDs` must also be a `Set<String>`
  /// of `WorkflowActionGroup.id` values for the containment check to be correct.
  ///
  /// `internal` (not `public`): exercised indirectly through `buildGroupState` in tests;
  /// no direct external callers exist outside `RunBotCore`.
  ///
  /// Fast-path guard safety: the skip condition is `existing.jobs.count >= group.jobs.count`.
  /// `group` comes from `snapPrev`, which is the previous poll's *live* snapshot captured
  /// before enrichment runs. `enrichCache` only mutates `newCache`, never `snapPrev`.
  /// Therefore `group.jobs.count` (unenriched snapshot) can never exceed
  /// `existing.jobs.count` (a cache entry that may have been enriched on a prior cycle),
  /// and the `>=` guard never skips a genuinely fresher entry.
  ///
  /// - Parameters:
  ///   - snapPrev: Live-group snapshot from the previous poll cycle (keyed by group ID).
  ///   - liveIDs: Group IDs present in the current live poll (non-completed only — see
  ///     `buildGroupState` for why completed groups are intentionally excluded).
  ///   - now: Timestamp used as `lastJobCompletedAt` for vanished groups that lack one.
  ///   - cache: Group cache to mutate in place.
  static func freezeVanishedGroups(
    snapPrev: [String: WorkflowActionGroup],
    liveIDs: Set<String>,
    now: Date,
    into cache: inout [String: WorkflowActionGroup]
  ) {
    log(
      "PollResultBuilder › freezeVanishedGroups — snapPrev=\(snapPrev.count) liveIDs=\(liveIDs.count)",
      category: .runner)
    for (groupID, group) in snapPrev where !liveIDs.contains(groupID) {
      if let existing = cache[groupID], existing.isDimmed, existing.jobs.count >= group.jobs.count {
        log(
          "PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) skipped (already cached+dimmed, jobs=\(existing.jobs.count)>=\(group.jobs.count))",
          category: .runner)
        continue
      }
      // This log line is only reached when the fast-path guard above was not taken.
      // dimmed= and cachedJobCount= expose exactly which subcase caused it:
      //   dimmed=false, cachedJobCount=0  → no prior cache entry (first-time freeze)
      //   dimmed=false, cachedJobCount>0  → entry exists but is not yet dimmed
      //   dimmed=true,  cachedJobCount<N  → entry is dimmed but has a stale job count
      let existing = cache[groupID]
      log(
        "PollResultBuilder › freezeVanishedGroups — vanished groupID=\(group.id)"
          + " dimmed=\(existing?.isDimmed ?? false)"
          + " cachedJobCount=\(existing?.jobs.count ?? 0)"
          + " snapshotJobCount=\(group.jobs.count)",
        category: .runner)
      if group.lastJobCompletedAt == nil {
        cache[groupID] = group.copying(isDimmed: true, settingCompletedAt: now)
      } else {
        cache[groupID] = group.copying(isDimmed: true)
      }
    }
  }

  /// Trims the group cache to at most `limit` entries, keeping the most recently completed.
  ///
  /// The sort is O(n log n), but with `groupCacheLimit = 30` this is completely
  /// irrelevant at runtime scale — do not optimise.
  ///
  /// The sort key uses two fallback levels (`lastJobCompletedAt ?? createdAt ?? .distantPast`)
  /// because groups can enter the cache before any of their jobs have finished — for example
  /// when `freezeVanishedGroups` freezes a group that had no recorded completion time.
  /// In that case `lastJobCompletedAt` is nil, so `createdAt` is used as a secondary
  /// recency signal to avoid all nil-date groups collapsing to `.distantPast` and being
  /// evicted arbitrarily. `trimJobCache` has no equivalent second fallback because
  /// `completedDate` is always set before a job is written into the job cache.
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
  /// Display order: in-progress -> loading -> queued -> cached (most-recently-completed first).
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

  /// Enriches the display array by running `enrichJobs` over each group's jobs
  /// concurrently via a `withTaskGroup`, preserving the original display sort order.
  ///
  /// `enrichJobs` must be `@escaping` because `addTask` captures it in an escaping closure.
  /// Keyed by `Int` (array index) so the order produced by `buildGroupDisplay` is
  /// faithfully restored after `withTaskGroup` yields results in completion order.
  private static func enrichDisplay(
    _ display: [WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) async -> [WorkflowActionGroup] {
    await withTaskGroup(of: (Int, WorkflowActionGroup).self) { group in
      for (idx, actionGroup) in display.enumerated() {
        group.addTask { (idx, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
      }
      var out: [(Int, WorkflowActionGroup)] = []
      for await pair in group { out.append(pair) }
      return out.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
  }

  /// Enriches the group cache by running `enrichJobs` over each cached group's
  /// jobs concurrently via a `withTaskGroup`.
  ///
  /// `enrichJobs` must be `@escaping` because `addTask` captures it in an escaping closure.
  /// Keyed by `String` (group ID) because `newCache` is a dictionary and its
  /// semantic identity IS the group ID. Kept separate from `enrichDisplay` because
  /// the key types differ (Int vs String) and the source collections differ
  /// (display array vs cache dict).
  private static func enrichCache(
    _ cache: [String: WorkflowActionGroup],
    enrichJobs: @escaping @Sendable ([ActiveJob]) async -> [ActiveJob]
  ) async -> [String: WorkflowActionGroup] {
    await withTaskGroup(of: (String, WorkflowActionGroup).self) { group in
      for (key, actionGroup) in cache {
        group.addTask { (key, actionGroup.withJobs(await enrichJobs(actionGroup.jobs))) }
      }
      var out: [String: WorkflowActionGroup] = [:]
      for await (key, actionGroup) in group { out[key] = actionGroup }
      return out
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
  /// Declared inside a `private extension` so it is file-scoped and not
  /// visible outside `PollResultBuilder.swift`. Not intended for use outside
  /// the polling pipeline; treat it as an implementation detail of
  /// `buildJobDisplay` and `buildGroupDisplay`.
  mutating func appendUpTo<S>(
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
