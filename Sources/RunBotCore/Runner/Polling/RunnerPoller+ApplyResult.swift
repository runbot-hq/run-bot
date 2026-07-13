// RunnerPoller+ApplyResult.swift
// RunBotCore

import Foundation
import GitHubClient

// swiftlint:disable:next missing_docs
extension RunnerPoller {

    // MARK: - Apply result

    /// Merges a completed fetch into actor state and pushes the snapshot to `RunnerState`.
    ///
    /// Clears `state.fetchError` on every successful cycle so the UI error banner
    /// dismisses automatically as soon as connectivity is restored. The write is
    /// guarded — if `fetchError` is already `nil` the assignment is skipped to
    /// avoid a spurious `@Observable` notification on every healthy poll cycle.
    func applyFetchResult(
        enrichedRunners: [GitHubRunner],
        jobResult: JobPollResult,
        groupResult: GroupPollResult
    ) async {
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
        // Update adaptive-interval counters after setDisplayState so that
        // hasActiveWork() reads the freshly-written self.jobs and self.actions.
        // Running this before setDisplayState would evaluate hasActiveWork() on
        // stale data from the previous cycle.
        if hasActiveWork() {
            consecutiveIdleTicks = 0
        } else {
            consecutiveIdleTicks += 1
        }
        lastBusyRunnerCount = runners.filter { $0.busy }.count
        // swiftlint:disable:next line_length
        log("RunnerPoller › fetch complete — actions=\(groupResult.display.count) jobs=\(jobResult.display.count) runners=\(enrichedRunners.count) isRateLimited=\(rateLimitSnapshot.isLimited) rateLimitResetDate=\(String(describing: rateLimitSnapshot.resetDate)) idleTicks=\(consecutiveIdleTicks) busyRunners=\(lastBusyRunnerCount)", category: .runner)
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
    /// `consecutiveIdleTicks` and `lastBusyRunnerCount` are also intentionally not updated
    /// here — both counters hold their last-successful-cycle values through any number of
    /// consecutive failures. See `RunnerPoller` state documentation for rationale.
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

// swiftlint:disable:next missing_docs
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
