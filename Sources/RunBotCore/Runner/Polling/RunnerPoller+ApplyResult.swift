// RunnerPoller+ApplyResult.swift
// RunBotCore

import Foundation
import GitHubClient
import UserNotifications

/// Applies a completed fetch result to actor state, triggers UI updates, and dispatches
/// local notifications for newly-concluded jobs.
extension RunnerPoller {

    // MARK: - Apply result

    /// Merges a completed fetch into actor state and pushes the snapshot to `RunnerState`.
    ///
    /// Clears `state.fetchError` on every successful cycle so the UI error banner
    /// dismisses automatically as soon as connectivity is restored. The write is
    /// guarded — if `fetchError` is already `nil` the assignment is skipped to
    /// avoid a spurious `@Observable` notification on every healthy poll cycle.
    ///
    /// After updating actor state, diffs `prevLiveJobs` against `newCache` to find
    /// jobs that concluded this cycle and fires a `UNUserNotificationCenter` request
    /// for each one, gated by `notificationPreferences.shouldNotify(conclusion:)`.
    ///
    /// Also detects runners that became busy this cycle (picked up work) and returns
    /// `true` so the call site (`fetchInternal`) can call `start()` with a fresh
    /// `activeScopes` snapshot — fulfilling the "fetch scopes and update main" contract
    /// from #2327 / #2365. `start()` is called at the `fetchInternal` level, not here,
    /// so it runs after this function returns and its stack frame is fully unwound.
    /// This avoids any interaction between `start()`'s cache-clear and the state
    /// written earlier in this function.
    ///
    /// **Pickup detection is not gated on notification authorisation.** A runner
    /// picking up work returns `true` (and `fetchInternal` will call `start()`) even
    /// when the `guard isAuthorized` block takes the early-return path. The early
    /// return exits only the `if !newlyCompleted.isEmpty` block — not the whole
    /// function — and `newlyPickedUp(prev:current:)` is called on both exit paths.
    ///
    /// **Why `start()` rather than a scoped re-read of `activeScopes`:**
    /// `scopesSnapshot` is captured once at the top of `fetchInternal()` and cannot
    /// be patched mid-cycle. `start()` is the only mechanism that produces a fetch
    /// cycle with a truly fresh snapshot. This mirrors the `startObservingScopes()`
    /// → `start()` path that already fires on scope changes.
    ///
    /// Also detects groups that transitioned from active to completed this cycle and
    /// enqueues one ZIP prefetch per `run.id` via `enqueueCompletionZIPs(groupResult:)`
    /// (#2488). Detection runs before `setDisplayState` so the previous `self.actions`
    /// value is still available for diffing.
    ///
    /// - Returns: `true` if one or more runners transitioned from idle to busy this
    ///   cycle; `false` otherwise. The caller is responsible for acting on this signal.
    @discardableResult
    func applyFetchResult(
        enrichedRunners: [GitHubRunner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult,
        pendingToRetry: [String: PendingFinalGroup] = [:]
    ) async -> Bool {
        // Capture the pre-update prevLiveJobs snapshot before writing new state.
        // Jobs that were live last cycle but are now in newCache concluded this cycle.
        let prevLive = prevLiveJobs

        // Capture busy-runner IDs before setDisplayState overwrites self.runners,
        // so we can diff against enrichedRunners afterwards to detect newly-busy runners.
        // (#2327) Must be captured here — after setDisplayState self.runners == enrichedRunners.
        //
        // Not a duplication of the newBusyIds expression below: these two Set(filter…map…)
        // expressions operate on different collections (self.runners vs enrichedRunners) at
        // different lifecycle points (pre- vs post-setDisplayState) and cannot be unified.
        let prevBusyIds = Set(runners.filter { $0.busy }.map { $0.id })

        let rateLimitSnapshot = await ghRateLimitSnapshot()
        completedCache = jobResult.newCache
        prevLiveJobs = jobResult.newPrevLive
        actionGroupCache = groupResult.newGroupCache
        prevLiveGroups = groupResult.newPrevLiveGroups
        // Merge the new pending groups from this cycle with the retried ones.
        // The retried entries (from prior cycles, now re-attempted) carry the
        // incremented attempt count. Newly unresolved groups from this cycle
        // carry `attempts: 1`. When both exist for the same key, the higher
        // attempt count wins (preserves the retry history).
        var mergedPending = groupResult.pendingFinalGroups
        for (key, retried) in pendingToRetry {
          // If the group was resolved into the cache this cycle, drop it.
          if groupResult.newGroupCache.keys.contains(key) { continue }
          // If the group was newly unresolved by buildGroupState, keep the
          // higher attempt count (the retried entry has more history).
          if let existing = mergedPending[key] {
            if retried.attempts > existing.attempts {
              mergedPending[key] = retried
            }
          } else {
            // The group was not resolved and not re-detected as vanished —
            // carry it forward for another retry.
            mergedPending[key] = retried
          }
        }
        pendingFinalGroups = mergedPending
        // Detect active → completed transitions and enqueue one ZIP per run (#2488).
        // Must run before setDisplayState overwrites self.actions with the new state.
        await enqueueCompletionZIPs(groupResult: groupResult)

        // setDisplayState writes the actor-local copies (self.runners / .jobs / .actions)
        // consumed by nextPollInterval() and other internal actor logic.
        setDisplayState(
            isRateLimited: rateLimitSnapshot.isLimited,
            rateLimitResetDate: rateLimitSnapshot.resetDate,
            runners: enrichedRunners,
            jobs: jobResult.display,
            actions: groupResult.display
        )
        // Update rateLimitRemaining from the live snapshot so nextPollInterval()
        // can engage the headroom-cooldown branch when approaching the quota wall.
        // Only updated when the header was present in the response; holds its
        // last-known value otherwise (same semantics as error cycles).
        if let remaining = rateLimitSnapshot.remaining {
            rateLimitRemaining = remaining
        }
        // Update adaptive-interval counters after setDisplayState so that
        // hasActiveWork() reads the freshly-written self.jobs and self.actions.
        // Running this before setDisplayState would evaluate hasActiveWork() on
        // stale data from the previous cycle.
        // Two independent signals feed PollIntervalStrategy:
        // - hasActiveWork() — job/action API state (drives the hasActiveWork gate)
        // - busyCount — runner.busy flag (drives the Fast/Mid/Slow tier ladder)
        // It is valid for these to disagree transiently (e.g. a runner is busy but
        // the job API hasn't surfaced it yet). In that case the active ladder is
        // entered only when hasActiveWork is true — intentional per #2069 design.
        // `enrichedRunners` is used here rather than `self.runners` because
        // setDisplayState wrote enrichedRunners into self.runners in the call above —
        // they are identical at this point. Using enrichedRunners directly avoids a
        // redundant property indirection and makes the value origin explicit.
        let busyCount = enrichedRunners.filter { $0.busy }.count
        let activeWork = hasActiveWork()
        let newIdleTicks = updateAdaptiveCounters(hasActiveWork: activeWork, busyRunnerCount: busyCount)
        // swiftlint:disable:next line_length
        log("RunnerPoller › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(rateLimitSnapshot.isLimited) rateLimitResetDate=\(String(describing: rateLimitSnapshot.resetDate)) rateLimitRemaining=\(rateLimitRemaining) idleTicks=\(newIdleTicks) busyRunners=\(busyCount)", category: .runner)
        // NOTE: actor-local properties (self.runners …) and the @Observable read model
        // (state.*) are two separate copies. setDisplayState (above) already wrote the
        // actor-local copies; the MainActor.run block below writes state.* — the view-layer
        // source of truth. The two writes are sequential, not atomic; no external code reads
        // actor-local state between them. See RunnerPoller.setDisplayState for the
        // write-through rationale.
        await MainActor.run { [state] in
            state.runners = enrichedRunners
            state.jobs = jobResult.display
            // Stable group ids (compositeCacheKey) mean SwiftUI diffs in-place;
            // no explicit animation wrapper needed here (#2688).
            state.actions = groupResult.display
            state.isRateLimited = rateLimitSnapshot.isLimited
            state.rateLimitResetDate = rateLimitSnapshot.resetDate
            if state.fetchError != nil { state.fetchError = nil }
        }

        // MARK: - Notification dispatch
        //
        // Find jobs that concluded this cycle: they were live last poll (prevLive)
        // but are now in newCache. Because prevLiveJobs only contains in-flight jobs
        // (never already-cached ones), no additional cross-check against the old
        // completedCache is required.
        //
        // `shouldNotify(conclusion:)` reads `notificationMode` on the @MainActor;
        // this hop is cheap and ensures a consistent read of the @Observable property.
        // Both `shouldFire` and `modeDescription` are captured in the same MainActor.run
        // block so no extra actor hop is needed for the skip log.
        // NOTE: This hop is inside the per-job loop because `shouldNotify(conclusion:)`
        // takes a per-job `conclusion` argument — it is not loop-invariant. Only
        // `modeDescription` (from the skip-log path) is stable, but splitting the hop
        // to hoist one String read is not worth the complexity. The `@MainActor` hop
        // is required for every job because `shouldNotify` is `@MainActor`-isolated.
        // `UNUserNotificationCenter.current()` is thread-safe and documented as safe to
        // call from any thread — no MainActor hop is needed for the notification center itself.
        let newlyCompleted = prevLive.values.filter { job in
            jobResult.newCache[job.id] != nil
        }
        if !newlyCompleted.isEmpty {
            let prefs = notificationPreferences
            // Capture notification settings once before the loop — authorization
            // status does not change mid-cycle, so checking it per-job is redundant.
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let isAuthorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard isAuthorized else {
                log(
                    "RunnerPoller › notifications skipped — permission denied (status=\(settings.authorizationStatus.rawValue))",
                    category: .runner)
                // NOTE: This return exits only the `if !newlyCompleted.isEmpty` block —
                // not the whole function. The runner-pickup Bool is computed and returned
                // below, after this block closes, regardless of notification auth status.
                return newlyPickedUp(prev: prevBusyIds, current: enrichedRunners)
            }
            for job in newlyCompleted {
                let conclusion = job.jobConclusion ?? .neutral
                // `.neutral` fallback for a nil conclusion (e.g. transient API gap):
                // 1. Maps to "Job completed" in notificationTitle (unambiguous label).
                // 2. Passes shouldNotify(.neutral) → `failuresOnly` returns false, `successesOnly`
                //    returns false, `never` returns false — so it's suppressed by any restrictive
                //    mode. Only `all` fires it, which is correct (user opted into everything).
                // 3. `.unknown` would also work but `.unknown` is for API strings the parser
                //    doesn't recognise; nil is not an unknown string, it's an absent value.
                let (shouldFire, modeDescription) = await MainActor.run {
                    (prefs.shouldNotify(conclusion: conclusion), prefs.notificationMode.rawValue)
                }
                guard shouldFire else {
                    log(
                        "RunnerPoller › notification skipped — job=\(job.name) conclusion=\(String(describing: job.jobConclusion)) mode=\(modeDescription)",
                        category: .runner)
                    continue
                }
                let content = UNMutableNotificationContent()
                content.title = conclusion.notificationTitle
                content.body = job.name
                content.sound = .default
                let request = UNNotificationRequest(
                    identifier: "job-\(job.id)",
                    // Stable job-ID key means UNUserNotificationCenter silently replaces any
                    // prior pending/delivered notification for the same job rather than
                    // stacking duplicates. This is intentional — a job should only produce
                    // one notification.
                    content: content,
                    trigger: nil
                )
                do {
                    try await UNUserNotificationCenter.current().add(request)
                    log(
                        "RunnerPoller › notification scheduled — job=\(job.name) title=\(conclusion.notificationTitle)",
                        category: .runner)
                } catch {
                    log(
                        "RunnerPoller › notification error — job=\(job.name) error=\(error)",
                        category: .runner)
                }
            }
        }

        return newlyPickedUp(prev: prevBusyIds, current: enrichedRunners)
    }

    /// Returns `true` and logs if any runner transitioned from idle to busy since the
    /// previous cycle; `false` (no log) otherwise.
    ///
    /// Extracted from `applyFetchResult` to keep the guard-return path in the
    /// notification block readable: both early-exit and normal-exit converge on the
    /// same call rather than duplicating the diff logic inline.
    ///
    /// - Parameters:
    ///   - prev: Busy-runner IDs captured before `setDisplayState` ran this cycle.
    ///   - current: The enriched runner list written by `setDisplayState` this cycle.
    private func newlyPickedUp(prev prevBusyIds: Set<Int>, current enrichedRunners: [GitHubRunner]) -> Bool {
        let newBusyIds = Set(enrichedRunners.filter { $0.busy }.map { $0.id })
        let pickedUp = newBusyIds.subtracting(prevBusyIds)
        guard !pickedUp.isEmpty else { return false }
        log(
            "RunnerPoller › runner(s) picked up work (ids=\(pickedUp.sorted())) — signalling fetchInternal to restart poll with fresh activeScopes",
            category: .runner
        )
        return true
    }

    /// Surfaces a fetch failure to the `RunnerState` read model.
    ///
    /// Mirrors `applyFetchResult` by updating both the actor-local rate-limit copies
    /// (`self.isRateLimited`, `self.rateLimitResetDate` — read by `nextPollInterval()`)
    /// and the `@Observable` read model (`state.*` — read by the view layer).
    /// Without this sync, a failed cycle while rate-limited would leave the actor-local
    /// copies stale, causing `nextPollInterval()` to compute the wrong cadence until the
    /// next successful `applyFetchResult`.
    ///
    /// Snapshots rate-limit state so the UI never shows both banners simultaneously:
    /// `clearGhRateLimit()` at the top of `fetchInternal()` clears the internal actor
    /// before any throw, so this snapshot reflects the cleared state.
    ///
    /// The `fetchError` write is guarded by a `localizedDescription` comparison to avoid
    /// re-notifying `@Observable` observers on every failed cycle when the message is
    /// unchanged (e.g. sustained network loss).
    ///
    /// Intentionally does **not** update `runners`, `jobs`, or `actions` — contrast with
    /// `applyFetchResult`, which passes all three to `setDisplayState`. Omitting them here
    /// means `setDisplayState` leaves those actor-local properties at their last-successful-
    /// cycle values. Views therefore show stale data alongside the error banner rather than
    /// an empty list.
    ///
    /// Intentionally does **not** detect runner pickup or call `start()`. On error cycles
    /// `enrichedRunners` is unavailable — there is no valid basis for a busy-runner diff.
    /// Restarting on a failed cycle would also risk thrashing during sustained connectivity
    /// loss. The scope-freshness guarantee from #2327 applies to successful cycles only.
    ///
    /// `consecutiveIdleTicks`, `lastBusyRunnerCount`, and `rateLimitRemaining` are also
    /// intentionally not updated here — all three counters hold their last-successful-cycle
    /// values through any number of consecutive failures. See `RunnerPoller` state
    /// documentation for rationale.
    func applyError(_ error: any Error & Sendable) async {
        let rateLimitSnapshot = await ghRateLimitSnapshot()
        // Sync actor-local copies first — nextPollInterval() reads these directly.
        setDisplayState(
            isRateLimited: rateLimitSnapshot.isLimited,
            rateLimitResetDate: rateLimitSnapshot.resetDate
        )
        await MainActor.run { [state] in
            // Guard the write: `any Error` is not Equatable, so compare via
            // `localizedDescription` — the only field `fetchErrorBanner` consumes.
            // Skipping the write when the message is unchanged avoids a spurious
            // `@Observable` notification on every failed poll cycle.
            if state.fetchError?.localizedDescription != error.localizedDescription {
                state.fetchError = error
            }
            state.isRateLimited = rateLimitSnapshot.isLimited
            state.rateLimitResetDate = rateLimitSnapshot.resetDate
        }
    }

    // MARK: - ZIP completion helper

    /// Detects groups that transitioned from active to completed this cycle and
    /// enqueues one ZIP prefetch per run (#2488).
    ///
    /// Builds a `ZIPCacheEntryKey` per run using the group's `headSha`,
    /// `normalizedEvent`, and `run.runAttempt` so that reruns never collide with
    /// previous attempts in the cache.
    ///
    /// Must be called before `setDisplayState` replaces `self.actions`.
    private func enqueueCompletionZIPs(groupResult: GroupPollResult) async {
        let previouslyActiveRunIDs = Set(
            actions
                .filter { $0.groupStatus != .completed }
                .flatMap { $0.runs }
                .map { $0.id }
        )
        let newlyCompleted = groupResult.display.filter { group in
            guard group.groupStatus == .completed else { return false }
            return group.runs.contains { previouslyActiveRunIDs.contains($0.id) }
        }
        for group in newlyCompleted {
            log(
                "RunnerPoller › ZIP completion transition — "
                    + "repo=\(group.repo) runIDs=\(group.runs.map(\.id))",
                category: .services
            )
            let groupKey = ZIPCacheGroupKey(
                repo: group.repo,
                headSha: group.headSha,
                normalizedEvent: group.normalizedEvent
            )
            for run in group.runs {
                let entryKey = ZIPCacheEntryKey(
                    group: groupKey,
                    runID: run.id,
                    runAttempt: run.runAttempt
                )
                await zipPrefetchQueue.enqueue(entryKey: entryKey, scope: group.repo, isCompleted: true)
            }
        }
    }
}
// MARK: - FetchError

/// Sendable-safe wrapper that bridges an arbitrary `any Error` across an actor boundary.
extension RunnerPoller {

    /// Sendable-safe wrapper that bridges an arbitrary `any Error` across an actor boundary.
    ///
    /// `any Error` is not `Sendable`, so passing it directly into `MainActor.run`
    /// produces a warning under `-strict-concurrency=complete`. `FetchError` captures
    /// `localizedDescription` — the only field read by `fetchErrorBanner` — and
    /// re-surfaces it as a `LocalizedError` conformance so the message is preserved.
    struct FetchError: LocalizedError, Sendable {
        /// The user-facing description forwarded from the underlying error.
        let errorDescription: String?
        /// Wraps `underlying`, capturing its `localizedDescription` as a `Sendable` string.
        init(_ underlying: any Error) { errorDescription = underlying.localizedDescription }
    }
}
