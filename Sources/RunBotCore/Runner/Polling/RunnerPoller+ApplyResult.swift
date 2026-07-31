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
    /// Also detects runners that became busy this cycle (picked up work) and calls
    /// `start()` to restart the poll loop with a fresh `activeScopes` snapshot,
    /// fulfilling the "fetch scopes and update main" contract from #2327 / #2365.
    /// `start()` cancels the current poll task before launching a new one, so this
    /// is a clean restart, not an additive one.
    ///
    /// A read-only `activeScopes` re-read with no downstream write was considered
    /// and rejected: `scopesSnapshot` is captured once at the top of `fetchInternal()`
    /// and cannot be patched mid-cycle. `start()` is the only mechanism that produces
    /// a fetch cycle with a fresh snapshot. This mirrors the `startObservingScopes()`
    /// → `start()` path that already fires on scope changes.
    ///
    /// **Ordering constraint:** notification dispatch runs before the runner-pickup
    /// block. `start()` clears `prevLiveJobs` and `completedCache`; dispatching
    /// notifications first ensures jobs that completed in the same cycle a runner
    /// picks up work are never silently dropped. The runner-pickup block is not
    /// extracted into a helper — its ordering relative to notification dispatch is
    /// load-bearing and would be obscured by indirection.
    ///
    /// **Function body length:** 70 non-comment lines (below the 90-line `swiftlint`
    /// warning threshold and 150-line error threshold). The notification-dispatch
    /// block (~20 code lines inside `if !newlyCompleted.isEmpty`) is intentionally
    /// kept inline here rather than extracted to a helper, because extracting it
    /// would require threading `prevLive`, `jobResult`, and `prefs` through an
    /// additional async actor hop boundary — the inline code is simpler and
    /// stays under the limit. Any future addition that risks exceeding 90 lines
    /// should extract the notification block into a private helper method.
    func applyFetchResult(
        enrichedRunners: [GitHubRunner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult
    ) async {
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
        // `enrichedRunners` is used here (not `self.runners`) because the values are
        // identical — `enrichedRunners` is exactly what setDisplayState wrote above —
        // so this is spec-equivalent to `runners.filter { $0.busy }.count`.
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
            state.actions = groupResult.display
            state.isRateLimited = rateLimitSnapshot.isLimited
            state.rateLimitResetDate = rateLimitSnapshot.resetDate
            if state.fetchError != nil { state.fetchError = nil }
        }

        // MARK: - Notification dispatch
        //
        // NOTE: This block runs before the runner-pickup block below. start() clears
        // prevLiveJobs and completedCache; dispatching notifications first ensures jobs
        // that completed in the same cycle a runner picks up work are never dropped.
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
                // NOT the whole function. The runner-pickup block (MARK below) runs after
                // this `if` closes and is unaffected by this return. All state writes
                // (completedCache, prevLiveJobs, MainActor.run state.*) happen before this
                // point. If future code is added inside this `if` block after the guard,
                // that code will also be skipped — keep any additions outside this block.
                return
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

        // MARK: - Runner pickup → restart poll with fresh scopes (#2327)
        //
        // NOTE: This block runs after notification dispatch (above). start() clears
        // prevLiveJobs and completedCache; notifications must fire first so same-cycle
        // job completions are not silently dropped when a runner also picks up work.
        //
        // When one or more runners became busy this cycle (transitioned from idle to
        // busy since the previous poll), call start() to restart the poll loop.
        // start() re-reads scopeStore.activeScopes as its first act, so the next
        // fetch cycle uses a guaranteed-fresh scope snapshot — fulfilling the
        // "fetch scopes and update main" contract from #2327.
        //
        // A read-only activeScopes re-read with no downstream write was considered and
        // rejected: scopesSnapshot is captured once at the top of fetchInternal() and
        // cannot be patched mid-cycle. start() is the only mechanism that produces a
        // fetch cycle with a fresh snapshot.
        //
        // start() cancels the existing poll task via pollLoop.setPollTask before
        // launching a new one, so this is a clean restart, not additive.
        //
        // This mirrors the existing startObservingScopes() → start() path that fires
        // when ScopeStore.activeScopes changes; runner pickup is a parallel trigger
        // using the same mechanism.
        //
        // Not extracted into a helper: ordering relative to notification dispatch is
        // load-bearing (see NOTE above); extraction would obscure that constraint.
        //
        // Double-trigger safety: the guard on newlyPickedUp.isEmpty means start() is
        // only called when at least one runner actually became busy this cycle,
        // keeping the common (idle) path free of any restart overhead.
        let newBusyIds = Set(enrichedRunners.filter { $0.busy }.map { $0.id })
        let newlyPickedUp = newBusyIds.subtracting(prevBusyIds)
        if !newlyPickedUp.isEmpty {
            let freshScopes = await MainActor.run { scopeStore.activeScopes }
            log(
                "RunnerPoller › runner(s) picked up work (ids=\(newlyPickedUp.sorted())) — restarting poll with fresh activeScopes count=\(freshScopes.count)",
                category: .runner
            )
            await start()
        }
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
