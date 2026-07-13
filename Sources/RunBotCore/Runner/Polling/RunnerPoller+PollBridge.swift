// RunnerPoller+PollBridge.swift
// RunBotCore

import Foundation
import GitHubClient
import os

// MARK: - RunnerPoller PollBridge

// These extensions delegate to PollResultBuilder so RunnerPoller.fetch() call
// sites are unchanged while the logic lives in the independently testable builder.

// swiftlint:disable missing_docs
/// `RunnerPoller` extension that bridges `PollResultBuilder` for the `fetch()` call sites.
///
/// All methods are `async` and run off the main actor during `await` — the
/// cooperative thread pool handles network work, and the continuation returns
/// to `@MainActor` automatically after each `await`.
/// `await MainActor.run { }` replaces the old `DispatchQueue.main.sync` pattern;
/// unlike `main.sync`, `MainActor.run` is re-entrant-safe and will not deadlock
/// when called from the main actor itself.
extension RunnerPoller {

    // MARK: - [weak self] in closures passed to buildJobState and buildGroupState
    //
    // The closures passed to both `buildJobState` and `buildGroupState` are captured
    // by the async frame for the full duration of each call. A strong `self` capture
    // would create a temporary reference cycle:
    //
    //   RunnerPoller (actor) → closures (in async frame) → RunnerPoller (strong)
    //
    // This cycle resolves once the builder call returns, so it is not a permanent leak.
    // However, it can delay deallocation if the actor is released while a fetch is in
    // flight (e.g. in tests or on settings change). `[weak self]` breaks the cycle
    // eagerly; the guard-let / optional-chain fallbacks in each closure handle nil safely.
    //
    // Note: `[weak self]` on a Swift actor is valid — actors are reference types.

    /// Builds a `JobPollResult` by fetching live jobs for all monitored scopes,
    /// backfilling step data from the cache, and diffing against `snapPrev`.
    ///
    /// - Parameter scopes: The scope snapshot captured by `fetchInternal`, threaded
    ///   through to `fetchAllJobs(scopes:)` to avoid a TOCTOU re-read of
    ///   `scopeStore.activeScopes`.
    func buildJobState(
        snapPrev: [Int: ActiveJob],
        snapCache: [Int: ActiveJob],
        scopes: [String]
    ) async -> JobPollResult {
        await PollResultBuilder.buildJobState(
            snapPrev: snapPrev,
            snapCache: snapCache,
            fetchJobs: { [weak self] in
                // weak: see [weak self] note above.
                guard let self else { return [] }
                return await self.fetchAllJobs(scopes: scopes)
            },
            backfill: { [weak self] cache in
                // weak: see [weak self] note above.
                // `self?` optional-chaining cannot be used with an inout argument.
                // Guard-unwrap to a concrete reference so the compiler accepts &cache.
                guard let self else { return }
                await self.backfillSteps(into: &cache)
            }
        )
    }

    /// Builds a `GroupPollResult` by fetching live workflow action groups for all monitored scopes,
    /// enriching jobs from the job cache, and diffing against `snapPrevGroups`.
    ///
    /// - Parameter scopes: The scope snapshot captured by `fetchInternal`, threaded
    ///   through to `fetchActionGroups(scopes:shaKeyedCache:)` to avoid a TOCTOU re-read
    ///   of `scopeStore.activeScopes`.
    func buildGroupState(
        snapPrevGroups: [String: WorkflowActionGroup],
        snapGroupCache: [String: WorkflowActionGroup],
        jobCache: [Int: ActiveJob],
        scopes: [String]
    ) async -> GroupPollResult {
        return await PollResultBuilder.buildGroupState(
            snapPrevGroups: snapPrevGroups,
            snapGroupCache: snapGroupCache,
            fetchGroups: { [weak self] shaKeyedCache in
                // weak: see [weak self] note above.
                await self?.fetchActionGroups(scopes: scopes, shaKeyedCache: shaKeyedCache) ?? []
            },
            enrichJobs: { [weak self] jobs in
                // weak: see [weak self] note above.
                self?.enrichGroupJobs(jobs, jobCache: jobCache) ?? jobs
            }
        )
    }

    // MARK: - Group helpers

    /// Enriches a group's job list with step and conclusion data from the job cache.
    ///
    /// `nonisolated`: pure map over `jobCache` (a value-type snapshot captured at the
    /// closure creation site) with no reads from `RunnerPoller`'s actor-isolated state.
    /// Marking it `nonisolated` removes the implicit `@MainActor` hop that was serialising
    /// every `withTaskGroup` child task in `PollResultBuilder.buildGroupState` through
    /// the main actor, negating the intended parallelism (#1153).
    ///
    /// `internal` (not `public`): called only via the `enrichJobs` closure passed to
    /// `PollResultBuilder` — no external callers exist outside `RunBotCore`.
    nonisolated func enrichGroupJobs(
        _ jobs: [ActiveJob],
        jobCache: [Int: ActiveJob]
    ) -> [ActiveJob] {
        jobs.map { job in
            guard let cached = jobCache[job.id] else { return job }
            let hasConclusion = jobCacheHasConclusion(job: job, cached: cached)
            let hasBetterSteps = jobCacheHasBetterSteps(job: job, cached: cached)
            guard hasConclusion || hasBetterSteps else { return job }
            return mergedJob(
                job: job,
                cached: cached,
                cacheHasConclusion: hasConclusion,
                cacheHasBetterSteps: hasBetterSteps)
        }
    }

    /// Returns `true` when the cache has settled a conclusion the live API hasn't returned yet.
    ///
    /// Common on the first poll after a job finishes — GitHub propagates conclusion
    /// slightly after status flips to "completed".
    ///
    /// Extracted from `enrichGroupJobs` to reduce its cyclomatic complexity (SW-R1002).
    nonisolated private func jobCacheHasConclusion(job: ActiveJob, cached: ActiveJob) -> Bool {
        // ActiveJob exposes jobConclusion (JobConclusion?), not conclusion (String?).
        cached.jobConclusion != nil && job.jobConclusion == nil
    }

    /// Returns `true` when the cache has fully-resolved steps while the live payload still shows
    /// in-progress ones (backfill ran after the main fetch).
    ///
    /// The `job.steps.isEmpty` short-circuit is intentional: when the live payload has no steps
    /// at all, there is no live data to protect — showing partial cached steps is better than
    /// zero rows for an entire poll cycle. The settled-cache guard only applies when the live
    /// payload itself has step entries that could be overwritten.
    ///
    /// Extracted from `enrichGroupJobs` to reduce its cyclomatic complexity (SW-R1002).
    nonisolated private func jobCacheHasBetterSteps(job: ActiveJob, cached: ActiveJob) -> Bool {
        // GitHubStep.status is a raw String — use stepStatus typed accessor from GitHubJob+AppExtensions.
        !cached.steps.isEmpty
            && (job.steps.isEmpty || job.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress }))
            && (job.steps.isEmpty || !cached.steps.contains(where: { (step: GitHubStep) in step.stepStatus == .inProgress }))
    }

    /// Merges `cached` data into `job` based on which cache advantage flags are set.
    ///
    /// When only `cacheHasConclusion`: bridges conclusion and completedAt from cache, uses live
    /// steps. GitHub transiently returns `conclusion != nil` with `completedAt == nil` for a brief
    /// window after a job finishes; without the cached fallback the completion timestamp would be
    /// lost for one poll cycle.
    ///
    /// When only `cacheHasBetterSteps`: keeps live conclusion and completedAt, bridges steps.
    ///
    /// Extracted from `enrichGroupJobs` to reduce its cyclomatic complexity (SW-R1002).
    nonisolated private func mergedJob(
        job: ActiveJob,
        cached: ActiveJob,
        cacheHasConclusion: Bool,
        cacheHasBetterSteps: Bool
    ) -> ActiveJob {
        if cacheHasConclusion {
            // ActiveJob.copying(conclusion:) takes JobConclusion?.
            // ActiveJob.copying(completedAt:) takes String? via raw.completedAt.
            return job
                .copying(conclusion: cached.jobConclusion)
                .copying(completedAt: cached.raw.completedAt ?? job.raw.completedAt)
                .copying(steps: cacheHasBetterSteps ? cached.steps : job.steps)
        } else {
            // cacheHasBetterSteps only — keep live conclusion and completedAt.
            return job.copying(steps: cached.steps)
        }
    }
}
// swiftlint:enable missing_docs
