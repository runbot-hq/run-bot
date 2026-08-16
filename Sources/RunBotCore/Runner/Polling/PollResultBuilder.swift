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
    fetchFinalRuns: (@Sendable ([WorkflowRunRef], String) async -> [RunPayload])? = nil
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
    // Dedupe by compositeCacheKey before writing — a transitional duplicate
    // (same composite key, two run-count snapshots) would otherwise overwrite
    // the first entry order-dependently (#2688).
    let dedupedDone: [WorkflowActionGroup] = {
      let coalesced = Dictionary(
        doneGroups.map { ($0.compositeCacheKey, $0) },
        uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
      )
      return Array(coalesced.values)
    }()
    for group in dedupedDone {
      let runSummary = group.runs.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", ")
      log(
        "PollResultBuilder › doneGroups — groupID=\(group.id) runs=[\(runSummary)]",
        category: .runner)
      newCache[group.compositeCacheKey] = group.copying(isDimmed: true)
    }
    // Resolve groups that vanished from the live and completed responses entirely.
    var (updatedCache, pendingFinalGroups) = await resolveVanishedAndFreeze(
      snapPrevGroups: snapPrevGroups,
      newCache: newCache,
      liveIDs: liveIDs,
      allFetched: allFetched,
      fetchFinalRuns: fetchFinalRuns,
      now: now
    )
    trimGroupCache(&updatedCache, limit: groupCacheLimit)
    // Dedupe liveGroups by stable composite id before any downstream use.
    // Dictionary(uniqueKeysWithValues:) traps on duplicate keys — use uniquingKeysWith
    // here so a transitional duplicate (same composite key, two run-count snapshots)
    // never causes a crash (#2688).
    let dedupedLive: [WorkflowActionGroup] = {
      let coalesced = Dictionary(
        liveGroups.map { ($0.id, $0) },
        uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
      )
      return coalesced.values.sorted { lhs, rhs in
        if lhs.groupStatus.sortPriority != rhs.groupStatus.sortPriority {
          return lhs.groupStatus.sortPriority < rhs.groupStatus.sortPriority
        }
        return (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
      }
    }()
    // Build newPrevLive from dedupedLive — safe because ids are now guaranteed unique.
    let newPrevLive = [String: WorkflowActionGroup](
      uniqueKeysWithValues: dedupedLive.map { ($0.id, $0) })
    let display = buildGroupDisplay(live: dedupedLive, cache: updatedCache)
    // Count from dedupedLive so a transitional duplicate does not inflate cadence
    // thresholds or badge counts (#2688).
    let inProgCount = dedupedLive.filter { $0.groupStatus == .inProgress }.count
    let queuedCount = dedupedLive.filter { $0.groupStatus == .queued }.count
    let loadingCount = dedupedLive.filter { $0.groupStatus == .loading }.count
    log(
      "PollResultBuilder › groups: \(inProgCount) in_progress \(queuedCount) queued \(loadingCount) loading"
        + " | cache: \(updatedCache.count) | display: \(display.count)",
      category: .runner
    )
    #if DEBUG
    for group in display {
      let dStart = group.jobs.compactMap { $0.raw.startDate }.min()
      let dEnd   = group.jobs.compactMap { $0.raw.completedDate }.max()
      log("[TimingTrace][display-group] id=\(group.id) status=\(group.groupStatus) jobs=\(group.jobs.count)", category: .runner)
      log("  storedStart=\(String(describing: group.firstJobStartedAt))", category: .runner)
      log("  storedEnd=\(String(describing: group.lastJobCompletedAt))", category: .runner)
      log("  derivedStart=\(String(describing: dStart)) derivedEnd=\(String(describing: dEnd)) duration=\(String(describing: group.completedDuration))", category: .runner)
    }
    #endif
    let enriched = await enrichDisplay(display, enrichJobs: enrichJobs)
    // Intentionally enriches the full newCache, not just live groups. The cache feeds
    // the next poll's display list; dimmed/completed groups that carry stale job data
    // would surface as incorrect enrichment on the following cycle if skipped here.
    let enrichedCache = await enrichCache(updatedCache, enrichJobs: enrichJobs)
    return GroupPollResult(
      display: enriched,
      newGroupCache: enrichedCache,
      newPrevLiveGroups: newPrevLive,
      pendingFinalGroups: pendingFinalGroups
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

  /// Resolves vanished groups and freezes remaining gaps into the cache.
  ///
  /// Identifies groups in `snapPrevGroups` that are absent from the fetched results
  /// (by `compositeCacheKey`), attempts to resolve their final state via
  /// `fetchFinalRuns`, and freezes any still-unresolved groups as dimmed.
  ///
  /// Identity is compared by `compositeCacheKey` so that a rerun with a new run ID
  /// but the same repo/SHA/event is not treated as a "vanished" group that could
  /// overwrite the newer entry (issue #2863).
  ///
  /// - Parameters:
  ///   - snapPrevGroups: The previous live groups snapshot.
  ///   - newCache: The group cache to mutate in place.
  ///   - liveIDs: IDs of groups in the current live response.
  ///   - allFetched: All groups fetched from the API this cycle.
  ///   - fetchFinalRuns: Optional closure that fetches terminal `RunPayload` values.
  ///   - now: The current timestamp.
  /// - Returns: The updated cache and a dictionary of pending final groups.
  private static func resolveVanishedAndFreeze(
    snapPrevGroups: [String: WorkflowActionGroup],
    newCache: [String: WorkflowActionGroup],
    liveIDs: Set<String>,
    allFetched: [WorkflowActionGroup],
    fetchFinalRuns: (@Sendable ([WorkflowRunRef], String) async -> [RunPayload])?,
    now: Date
  ) async -> (newCache: [String: WorkflowActionGroup], pendingFinalGroups: [String: PendingFinalGroup]) {
    let fetchedCompositeKeys = Set(allFetched.map { $0.compositeCacheKey })
    var pendingFinalGroups: [String: PendingFinalGroup] = [:]
    var newCache = newCache
    let vanishedGroups = snapPrevGroups.values.filter { group in
      guard !group.isCompleted else { return false }
      guard !fetchedCompositeKeys.contains(group.compositeCacheKey) else { return false }
      return true
    }
    if !vanishedGroups.isEmpty, let fetchFinalRuns {
      let resolution = await resolveVanishedGroups(
        vanished: Array(vanishedGroups),
        fetchFinalRuns: fetchFinalRuns,
        now: now
      )
      for (key, resolvedGroup) in resolution.resolved where !fetchedCompositeKeys.contains(key) {
        newCache[key] = resolvedGroup
      }
      for pending in resolution.unresolved where !fetchedCompositeKeys.contains(pending.group.compositeCacheKey) {
        pendingFinalGroups[pending.group.compositeCacheKey] = pending
      }
    }
    // freezeVanishedGroups must skip groups that are pending resolution — otherwise
    // it would freeze the stale blue snapshot before the retry has a chance to succeed.
    let pendingKeys = Set(pendingFinalGroups.keys)
    freezeVanishedGroups(
      snapPrev: snapPrevGroups,
      liveIDs: liveIDs,
      pendingKeys: pendingKeys,
      now: now,
      into: &newCache
    )
    return (newCache, pendingFinalGroups)
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
  /// The composite key is `WorkflowActionGroup.compositeCacheKey` (`"repo:headSha:normalizedEvent"`)
  /// — defined on the model so producer (`PollResultBuilder`) and consumer
  /// (`WorkflowActionGroupFetcher`) share a single canonical format and cannot drift.
  /// A pure `headSha` key would cause 100% cache misses for completed runs when
  /// the event differs (regression from #2434). `repo` is included so that two scopes
  /// sharing a commit do not collide into one row (#2688).
  public static func makeShaKeyedCache(_ cache: [String: WorkflowActionGroup]) -> [String: WorkflowActionGroup] {
    Dictionary(
      cache.values.map { ($0.compositeCacheKey, $0) },
      uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
    )
  }

  /// Removes cache entries whose composite identity (`repo:headSha:normalizedEvent`) appears
  /// in the freshly-fetched group list.
  ///
  /// - Parameter cache: The composite-keyed group cache (`snapGroupCache`). Each entry's
  ///   key equals `group.id` == `group.compositeCacheKey` after the #2688 stable-id fix.
  /// - Parameter freshGroups: The groups returned by the current live fetch.
  ///
  /// Evicting by composite identity ensures that a fresh `push` group does not
  /// accidentally evict a cached `workflow_dispatch` group sharing the same SHA
  /// but belonging to a different event bucket. `repo` is also included so that two
  /// scopes sharing a commit do not cross-evict each other.
  public static func evictFreshShas(
    from cache: [String: WorkflowActionGroup],
    freshGroups: [WorkflowActionGroup]
  ) -> [String: WorkflowActionGroup] {
    // Cache is composite-keyed (group.compositeCacheKey == group.id after Change 2).
    // Using $0.key is now equivalent to $0.value.compositeCacheKey, but we derive from
    // the value to stay consistent with the canonical key definition on WorkflowActionGroup.
    let freshKeys = Set(freshGroups.map { $0.compositeCacheKey })
    return cache.filter { !freshKeys.contains($0.value.compositeCacheKey) }
  }

  /// Freezes action groups that were live in the previous poll but have since
  /// vanished from the live feed (i.e. completed without appearing in fetchGroups).
  ///
  /// Vanished groups are written into `cache` dimmed. Both `snapPrev` and `cache`
  /// are keyed by `WorkflowActionGroup.id` (== `compositeCacheKey` after #2688 fix);
  /// `liveIDs` must also be a `Set<String>` of those same values for the containment
  /// check to be correct.
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
  /// Resolves groups that disappeared from both the live and completed API responses.
  ///
  /// For each vanished group, fetches every run's terminal state concurrently.
  /// If all runs now have a conclusion, builds an updated group with resolved
  /// `WorkflowRunRef` values and returns it as resolved.
  ///
  /// Groups whose runs cannot be resolved (API error, missing conclusion, or
  /// partial data) are returned as unresolved so the caller can retry on the
  /// next poll cycle (issue #2859, #2863).
  ///
  /// - Parameters:
  ///   - vanished: Groups present in `snapPrevGroups` but absent from `allFetched`.
  ///   - fetchFinalRuns: Closure that fetches terminal `RunPayload` values for the
  ///     given run refs and scope. Returns resolved payloads (may be partial).
  ///   - now: Timestamp used as `lastJobCompletedAt` when none is recorded.
  /// - Returns: A tuple containing resolved groups (keyed by compositeCacheKey) and
  ///   unresolved groups that should be retried.
  static func resolveVanishedGroups(
    vanished: [WorkflowActionGroup],
    fetchFinalRuns: @escaping @Sendable ([WorkflowRunRef], String) async -> [RunPayload],
    now: Date
  ) async -> (resolved: [(String, WorkflowActionGroup)], unresolved: [PendingFinalGroup]) {
    var resolved: [(String, WorkflowActionGroup)] = []
    var unresolved: [PendingFinalGroup] = []
    await withTaskGroup(of: (String, WorkflowActionGroup, PendingFinalGroup?)?.self) { group in
      for wag in vanished {
        let key = wag.compositeCacheKey
        let runs = wag.runs
        let scope = wag.repo
        group.addTask {
          let payloads = await fetchFinalRuns(runs, scope)
          let payloadByID: [Int: RunPayload] = Dictionary(
            payloads.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, _ in lhs }
          )
          // Build updated WorkflowRunRef values from fetched payloads.
          let updatedRuns: [WorkflowRunRef] = runs.map { ref in
            guard let payload = payloadByID[ref.id] else { return ref }
            return WorkflowRunRef(
              id: ref.id,
              name: ref.name,
              status: payload.status,
              conclusion: payload.conclusion,
              htmlUrl: ref.htmlUrl,
              runAttempt: ref.runAttempt
            )
          }
          // Only resolve when every run has a conclusion — partial data is unsafe.
          guard updatedRuns.allSatisfy({ $0.conclusion != nil }) else {
            // Return unresolved for retry on the next poll cycle.
            let pending = PendingFinalGroup(group: wag, attempts: 1)
            log(
              "PollResultBuilder › resolveVanishedGroups — UNRESOLVED groupID=\(wag.id) "
                + "runs=\(updatedRuns.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", "))",
              category: .runner
            )
            return (key, wag, pending)
          }
          let updatedGroup = WorkflowActionGroup(
            headSha: wag.headSha,
            label: wag.label,
            title: wag.title,
            headBranch: wag.headBranch,
            repo: wag.repo,
            runs: updatedRuns,
            jobs: wag.jobs,
            firstJobStartedAt: wag.firstJobStartedAt,
            lastJobCompletedAt: wag.lastJobCompletedAt ?? now,
            createdAt: wag.createdAt,
            normalizedEvent: wag.normalizedEvent,
            isDimmed: true
          )
          log(
            "PollResultBuilder › resolveVanishedGroups — resolved groupID=\(wag.id) "
              + "runs=\(updatedRuns.map { "\($0.id):\($0.conclusion?.rawValue ?? "nil")" }.joined(separator: ", "))",
            category: .runner
          )
          return (key, updatedGroup, nil)
        }
      }
      for await result in group {
        guard let (key, wagOrResolved, pending) = result else { continue }
        if let pending {
          unresolved.append(pending)
        } else {
          resolved.append((key, wagOrResolved))
        }
      }
    }
    return (resolved, unresolved)
  }

  /// Freezes groups that have vanished from the live feed into the cache as dimmed.
  ///
  /// A group "vanishes" when it appeared in `snapPrev` but is absent from the current
  /// live set (`liveIDs`). Such groups are frozen into the cache with `isDimmed: true`
  /// so they remain visible in the display until evicted.
  ///
  /// Groups whose `compositeCacheKey` is in `pendingKeys` are skipped — they are awaiting
  /// final-state resolution and will be retried on the next poll cycle (issue #2859, #2863).
  ///
  /// - Parameters:
  ///   - snapPrev: The previous live groups snapshot.
  ///   - liveIDs: IDs of groups in the current live response.
  ///   - pendingKeys: Set of `compositeCacheKey` values to skip (pending resolution).
  ///   - now: The current timestamp, used as `lastJobCompletedAt` when none is recorded.
  ///   - cache: The group cache to mutate in place.
  static func freezeVanishedGroups(
    snapPrev: [String: WorkflowActionGroup],
    liveIDs: Set<String>,
    pendingKeys: Set<String> = [],
    now: Date,
    into cache: inout [String: WorkflowActionGroup]
  ) {
    log(
      "PollResultBuilder › freezeVanishedGroups — snapPrev=\(snapPrev.count) liveIDs=\(liveIDs.count) pendingKeys=\(pendingKeys.count)",
      category: .runner)
    for (groupID, group) in snapPrev where !liveIDs.contains(groupID) {
      // Skip groups that are pending final-state resolution — they will be retried
      // on the next poll cycle (issue #2859, #2863).
      if pendingKeys.contains(group.compositeCacheKey) {
        log(
          "PollResultBuilder › freezeVanishedGroups — groupID=\(group.id) skipped (pending resolution)",
          category: .runner)
        continue
      }
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
      uniqueKeysWithValues: sorted.prefix(limit).map { group in (group.compositeCacheKey, group) })
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

  // MARK: - Private helpers — moved to PollResultBuilder+Enrichment.swift
}
