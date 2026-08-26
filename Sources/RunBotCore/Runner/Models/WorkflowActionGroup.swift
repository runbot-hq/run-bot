// WorkflowActionGroup.swift
// RunBotCore
import Foundation

// MARK: - WorkflowActionGroup + RBStatus

// swiftlint:disable:next missing_docs
extension WorkflowActionGroup {
    /// Canonical `RBStatus` derived from both the group's status and its conclusion.
    ///
    /// Mirrors the legacy `ActionRowView.rowStatus` mapping so the windowed app
    /// and the status-bar app show identical conclusion colours.
    public var rbStatus: RBStatus {
        switch groupStatus {
        case .inProgress: return .inProgress
        case .loading:    return .queued
        case .queued:     return .queued
        case .completed:  return completedRBStatus
        }
    }

    /// Conclusion-aware status for completed workflow groups.
    private var completedRBStatus: RBStatus {
        switch conclusion {
        case .success:
            return .success
        case .failure, .timedOut, .actionRequired, .startupFailure:
            return .failed
        case .cancelled:
            return .cancelled
        case .skipped:
            return .skipped
        case .neutral, .stale, .unknown, nil:
            return .unknown
        }
    }
}

// MARK: - WorkflowActionGroup

/// Represents one **commit / PR trigger**: all GitHub Actions workflow runs
/// that share the same `head_sha`. Mirrors ci-dash.py's "Group" concept from
/// `group_runs()` + `enrich_group()`.
///
/// Hierarchy: `WorkflowActionGroup` → jobs (flat across all sibling runs) → `JobStep` → log.
/// `ActionDetailView` drills into the flat job list; `JobDetailView`/`StepLogView`
/// are reused unchanged below that.
public struct WorkflowActionGroup: Identifiable, Equatable, Sendable {
    /// The git commit SHA that triggered this group of runs.
    public let headSha: String
    /// Short display label: `"#1270"` for PRs, `"d6281b"` (sha[:7]) for push events.
    public let label: String
    /// Commit or PR message first line, truncated to 40 characters.
    public let title: String
    /// The branch this group was triggered on.
    public let headBranch: String?
    /// The `owner/repo` scope string for this group.
    public let repo: String
    /// Normalised trigger event bucket, e.g. `"commit"` or `"workflow_dispatch"`.
    ///
    /// Derived from `groupEvent(_:)` in `WorkflowActionGroupFetcher` and stored here
    /// so `PollResultBuilder.makeShaKeyedCache` can produce the same composite cache
    /// key (`"headSha:normalizedEvent"`) that `WorkflowActionGroupFetcher` uses when
    /// looking up entries — preventing the 100% cache-miss rate introduced by #2434.
    public let normalizedEvent: String

    /// All sibling workflow runs sharing this `head_sha`.
    public let runs: [WorkflowRunRef]

    /// Static helper so both `WorkflowActionGroup.compositeCacheKey` and
    /// `GroupKey.cacheKey` (in `WorkflowActionGroupFetcher.swift`) share a
    /// single physical definition of the cache key format.
    ///
    /// This is the CANONICAL definition. If the format ever changes, it changes here
    /// and here only — both callers pick it up automatically.
    ///
    /// `repo` is included so that two scopes sharing a commit (fork, mirror, monorepo
    /// split) do not collide into one row when `fetchActionGroups` merges groups from
    /// every active scope into a single display list.
    public static func compositeCacheKey(repo: String, headSha: String, normalizedEvent: String) -> String {
        "\(repo):\(headSha):\(normalizedEvent)"
    }

    /// The composite cache key for this group instance.
    /// Delegates to the static overload — format is defined in exactly one place.
    public var compositeCacheKey: String {
        Self.compositeCacheKey(repo: repo, headSha: headSha, normalizedEvent: normalizedEvent)
    }

    /// Stable Identifiable key: `repo:headSha:normalizedEvent`.
    ///
    /// Survives status changes, added runs, and re-runs — SwiftUI diffs the group
    /// as an in-place update instead of a remove+insert pair, eliminating the
    /// duplicate-row animation glitch (#2688).
    public var id: String { compositeCacheKey }

    /// Newest run ID in the group (numeric). Use this for recency comparisons
    /// anywhere the old `id` was used as a run-ID proxy (tiebreaks, log correlation).
    public var latestRunID: Int { runs.map { $0.id }.max() ?? 0 }

    /// All jobs across every run in this group, fetched and flattened.
    /// This is what `ActionDetailView` renders.
    public let jobs: [ActiveJob]

    /// UTC time of the earliest job `startedAt` across all runs.
    /// Mirrors ci-dash.py's `first_job_started_at`.
    public let firstJobStartedAt: Date?

    /// UTC time of the latest job `completedAt` across all runs.
    /// Mirrors ci-dash.py's `last_job_completed_at`.
    public let lastJobCompletedAt: Date?

    /// Fallback creation time from the representative run.
    public let createdAt: Date?

    /// Set to `true` when frozen into `actionGroupCache` after completion.
    ///
    /// - Note: `WorkflowActionGroup+Progress.swift` (RunBot target) declares a computed
    ///   `var isDimmed` that derives visual-dimming from `conclusion`. The two serve different
    ///   purposes: this stored property is the freeze-cache flag; the computed one is the
    ///   view-layer opacity signal. They live in separate targets and do not shadow each other,
    ///   but the shared name can mislead readers of this struct definition.
    public let isDimmed: Bool

    // MARK: Equatable

    // Equality is SYNTHESIZED (memberwise) — deliberately no custom `==`.
    //
    // ⚠️ Do NOT reintroduce identity-based (`lhs.id == rhs.id`) equality here.
    // SwiftUI decides whether to re-invoke a view's `body` by comparing the view's
    // stored properties with `==`. The shell rows and columns
    // (`WorkflowRow`, `WorkflowSelection`) store a
    // `WorkflowActionGroup` / `[WorkflowActionGroup]` directly, so an id-only `==`
    // made every post-conclusion snapshot compare "equal" and SwiftUI skipped the
    // re-render — the status dot stayed blue until the view was recreated by
    // navigating away and back (#2859, #2870).
    //
    // Memberwise equality covers `runs`, `jobs`, and `isDimmed`, which are exactly
    // the inputs of the derived `groupStatus` / `conclusion` / `rbStatus`, so any
    // status or conclusion change now invalidates the observing views in place.
    // `id` remains stable across polls, so `List`/`ForEach` still diff groups as
    // in-place updates rather than remove+insert pairs (#2688 stays fixed).
    //
    // Cost note: `onChange(of: store.actions)` in `PanelMainView` now deep-compares
    // job arrays once per poll snapshot. The lists involved are tens of value
    // structs — negligible next to the network fetch that produced them.

    /// Returns a copy of this group with a replacement jobs array.
    ///
    /// Used in `RunnerStore` to enrich job data without reconstructing the
    /// full struct at every call site.
    public func withJobs(_ newJobs: [ActiveJob]) -> WorkflowActionGroup {
        WorkflowActionGroup(
            headSha: headSha,
            label: label,
            title: title,
            headBranch: headBranch,
            repo: repo,
            runs: runs,
            jobs: newJobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt,
            normalizedEvent: normalizedEvent,
            isDimmed: isDimmed
        )
    }

    /// Returns a copy of this group with `isDimmed` set. All other fields are preserved verbatim.
    public func copying(isDimmed: Bool) -> WorkflowActionGroup {
        WorkflowActionGroup(
            headSha: headSha,
            label: label,
            title: title,
            headBranch: headBranch,
            repo: repo,
            runs: runs,
            jobs: jobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: lastJobCompletedAt,
            createdAt: createdAt,
            normalizedEvent: normalizedEvent,
            isDimmed: isDimmed
        )
    }

    /// Returns a copy of this group with `isDimmed` set and `lastJobCompletedAt` set to `date`.
    ///
    /// Use this overload when the completion timestamp is not yet recorded on the group
    /// (i.e. the group vanished from the live feed before the API returned a final time).
    /// All other fields are preserved verbatim.
    public func copying(isDimmed: Bool, settingCompletedAt date: Date) -> WorkflowActionGroup {
        WorkflowActionGroup(
            headSha: headSha,
            label: label,
            title: title,
            headBranch: headBranch,
            repo: repo,
            runs: runs,
            jobs: jobs,
            firstJobStartedAt: firstJobStartedAt,
            lastJobCompletedAt: date,
            createdAt: createdAt,
            normalizedEvent: normalizedEvent,
            isDimmed: isDimmed
        )
    }

    /// Creates a new `WorkflowActionGroup`.
    /// - Parameters:
    ///   - headSha: The git commit SHA.
    ///   - label: Short display label (`"#1270"` or `"d6281b"`).
    ///   - title: Commit/PR message first line, ≤40 chars.
    ///   - headBranch: The triggering branch name.
    ///   - repo: The `owner/repo` scope string.
    ///   - runs: Sibling workflow runs sharing this SHA.
    ///   - jobs: Flattened job list. Defaults to empty.
    ///   - firstJobStartedAt: Earliest job start time across all runs.
    ///   - lastJobCompletedAt: Latest job completion time across all runs.
    ///   - createdAt: Fallback creation time from the representative run.
    ///   - normalizedEvent: Normalised trigger event bucket (e.g. `"commit"`, `"workflow_dispatch"`). Defaults to `"commit"`.
    ///   - isDimmed: `true` when frozen into the completed cache. Defaults to `false`.
    public init(
        headSha: String,
        label: String,
        title: String,
        headBranch: String?,
        repo: String,
        runs: [WorkflowRunRef],
        jobs: [ActiveJob] = [],
        firstJobStartedAt: Date? = nil,
        lastJobCompletedAt: Date? = nil,
        createdAt: Date? = nil,
        normalizedEvent: String = "commit",
        isDimmed: Bool = false
    ) {
        self.headSha = headSha
        self.label = label
        self.title = title
        self.headBranch = headBranch
        self.repo = repo
        self.runs = runs
        self.jobs = jobs
        self.firstJobStartedAt = firstJobStartedAt
        self.lastJobCompletedAt = lastJobCompletedAt
        self.createdAt = createdAt
        self.normalizedEvent = normalizedEvent
        self.isDimmed = isDimmed
    }

    // MARK: - Derived properties

    /// Group status derived from run-level statuses and job conclusions.
    ///
    /// Priority order:
    /// 1. `.completed` — all sibling runs have concluded **and** all loaded jobs have
    ///    a conclusion. The run-level guard prevents a partially-loaded sibling run
    ///    (whose jobs haven't arrived yet) from being prematurely frozen: job conclusions
    ///    from other runs could otherwise satisfy `allSatisfy` while the sibling is
    ///    still in progress.
    /// 2. `.inProgress` — any sibling run is currently running.
    /// 3. `.queued` — any sibling run is queued but none is running.
    /// 4. `.loading` — jobs have not arrived yet and no run is actively running or queued.
    ///    Prevents the silent fallthrough to `.completed` during the initial fetch window.
    public var groupStatus: GroupStatus {
        let allRunsConcluded = runs.allSatisfy { $0.conclusion != nil }
        if allRunsConcluded, jobsTotal > 0, jobs.allSatisfy({ $0.jobConclusion != nil }) {
            return .completed
        }
        if runs.contains(where: { $0.status == .inProgress }) { return .inProgress }
        if runs.contains(where: { $0.status == .queued }) { return .queued }
        if jobs.isEmpty && !allRunsConcluded { return .loading }
        return .completed
    }

    /// Group conclusion derived preferentially from jobs, falling back to runs.
    ///
    /// ⚠️ WHY WE USE JOBS, NOT RUNS:
    /// The GitHub API can report a run-level conclusion of `"failure"` even when every
    /// individual job succeeded. This happens when a job was retried: the first
    /// attempt creates a run whose conclusion is `"failure"`, but the retry run's jobs
    /// all show `"success"`. Since we flatten all jobs from all sibling runs, using
    /// job-level conclusions is authoritative.
    ///
    /// Priority order: failure > cancelled > skipped > success.
    ///
    /// Returns `nil` while jobs are still loading (`jobs.isEmpty`) or while any job
    /// has not yet concluded, to prevent a premature FAILED badge.
    ///
    /// ⚠️ NORMALISATION NOTE — run-based fallback:
    /// The run-based fallback (reached only while `jobs.isEmpty`) returns
    /// `JobConclusion.failure` for **all** `isFailure` conclusions, including `.actionRequired`,
    /// `.timedOut`, and `.startupFailure`. This is intentional: the run-based path is a
    /// **loading-state placeholder** only. Once jobs populate, the job-based path above
    /// takes over with the precise `JobConclusion` value. Callers can switch on the enum
    /// directly for full type-safety.
    public var conclusion: JobConclusion? {
        if !jobs.isEmpty {
            guard jobs.allSatisfy({ $0.jobConclusion != nil }) else { return nil }
            if let failedJob = jobs.first(where: { $0.jobConclusion?.isFailure == true }) {
                return failedJob.jobConclusion
            }
            if jobs.contains(where: { $0.jobConclusion == .cancelled }) { return .cancelled }
            let hasSuccess = jobs.contains(where: { $0.jobConclusion == .success })
            let allJobsSkipped = jobs.allSatisfy { $0.jobConclusion == .skipped }
            if !hasSuccess && allJobsSkipped { return .skipped }
            return .success
        }
        guard runs.allSatisfy({ $0.conclusion != nil }) else { return nil }
        if runs.contains(where: { $0.conclusion?.isFailure == true }) { return .failure }
        if runs.contains(where: { $0.conclusion == .cancelled }) { return .cancelled }
        if runs.contains(where: { $0.conclusion == .skipped }) { return .skipped }
        if runs.allSatisfy({ $0.conclusion == .neutral || $0.conclusion == .stale || $0.conclusion == .skipped }) { return nil }
        return .success
    }

    /// Number of jobs with a concluded result across all sibling runs.
    public var jobsDone: Int { jobs.filter { $0.jobConclusion != nil }.count }

    /// Number of successfully concluded jobs across all sibling runs.
    public var jobsSucceeded: Int { jobs.filter { $0.jobConclusion == .success }.count }

    /// Total job count across all sibling runs.
    public var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction showing successful vs total jobs, e.g. `"3/5"`.
    /// Returns `"—"` while jobs load.
    public var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsSucceeded)/\(jobsTotal)" }

    /// Name of the first in-progress job, or first queued job, or `"—"`.
    public var currentJobName: String {
        if let job = jobs.first(where: { $0.jobStatus == .inProgress }) { return job.name }
        if let job = jobs.first(where: { $0.jobStatus == .queued }) { return job.name }
        return "—"
    }

    /// Human-readable elapsed duration derived from `firstJobStartedAt` → `lastJobCompletedAt`.
    /// Falls back to `createdAt` when no job timing is available.
    public var elapsed: String {
        formatElapsed(
            start: firstJobStartedAt ?? createdAt,
            end: lastJobCompletedAt,
            isCompleted: groupStatus == .completed
        )
    }

    /// Total duration of a completed workflow, measured from the first job start
    /// to the final job completion.
    ///
    /// Returns `nil` for active workflows, missing timestamps, or invalid
    /// completion times (end before start).
    public var completedDuration: TimeInterval? {
        guard groupStatus == .completed else { return nil }

        // Derive timestamps from individual jobs when aggregate fields are absent.
        // This protects the UI if stored aggregates are dropped during a cache/copy
        // transition while per-job timestamps remain available.
        let derivedStart = jobs.compactMap { $0.raw.startDate }.min()
        let derivedEnd   = jobs.compactMap { $0.raw.completedDate }.max()

        let start = firstJobStartedAt ?? derivedStart
        let end   = lastJobCompletedAt ?? derivedEnd

        guard let start, let end, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    // MARK: - Runner type

    /// `true` if at least one job in this group ran on a local (self-hosted) runner.
    /// `false` if all assigned jobs ran on GitHub-hosted runners.
    /// `nil` if no job has been assigned to a runner yet (all still queued).
    ///
    /// Detection: any job with `isLocalRunner == true` → local; any job with
    /// `isLocalRunner == false` → cloud; remaining `nil`s are ignored.
    /// Priority: local wins over cloud (mixed groups show the local icon).
    public var isLocalGroup: Bool? {
        let known = jobs.compactMap { $0.isLocalRunner }
        guard !known.isEmpty else { return nil }
        return known.contains(true)
    }
}
