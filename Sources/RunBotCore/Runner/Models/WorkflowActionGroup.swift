// WorkflowActionGroup.swift
// RunBotCore
import Foundation

// MARK: - GroupStatus

/// Type-safe status for a workflow run group (commit/PR trigger).
/// Mirrors ci-dash.py's group status derivation logic.
public enum GroupStatus {
    /// At least one sibling run is in progress.
    case inProgress
    /// Jobs have not yet loaded and no run is active — transient fetch window.
    case loading
    /// No run is in progress, but at least one is queued.
    case queued
    /// All runs have concluded (or all jobs are done).
    case completed
}

// MARK: - GroupStatus + display helpers

/// Display and sorting helpers for `GroupStatus`.
extension GroupStatus {
    /// Sort priority for display ordering.
    ///
    /// Lower value = higher display priority (in-progress before loading before queued before completed).
    public var sortPriority: Int {
        switch self {
        case .inProgress: return 0
        case .loading:    return 1
        case .queued:     return 2
        case .completed:  return 3
        }
    }
}

// MARK: - WorkflowRunRef

/// Lightweight reference to a single workflow run inside a `WorkflowActionGroup`.
///
/// Holds only the data needed for display and job fetching — deliberately
/// minimal so the full job list lives on the parent `WorkflowActionGroup` instead.
public struct WorkflowRunRef: Identifiable, Sendable {
    /// The unique GitHub run ID.
    public let id: Int
    /// Workflow file name, e.g. `"SonarQube"`, `"vitest"`.
    public let name: String
    /// Current run status as a typed `JobStatus` value.
    public let status: JobStatus
    /// Run conclusion once completed, or `nil` while running.
    public let conclusion: JobConclusion?
    /// URL to the run detail page on github.com.
    public let htmlUrl: String?

    /// Creates a new `WorkflowRunRef`.
    /// - Parameters:
    ///   - id: The unique GitHub run ID.
    ///   - name: Workflow file name.
    ///   - status: Current run status.
    ///   - conclusion: Run conclusion, or `nil` while running.
    ///   - htmlUrl: URL to the run detail page.
    public init(id: Int, name: String, status: JobStatus, conclusion: JobConclusion?, htmlUrl: String?) {
        self.id = id
        self.name = name
        self.status = status
        self.conclusion = conclusion
        self.htmlUrl = htmlUrl
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

    /// All sibling workflow runs sharing this `head_sha`.
    public let runs: [WorkflowRunRef]

    /// Stable unique key: highest run ID in this group.
    ///
    /// Run IDs are unique and monotonically increasing — immune to `head_sha` collisions
    /// caused by scheduled workflows firing on the same commit.
    public var id: String { String(runs.map { $0.id }.max() ?? 0) }

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

    /// Identity-based equality: two groups are equal when their stable `id` matches.
    ///
    /// This satisfies the `onChange(of: store.actions)` requirement in `PanelMainView`
    /// without deep-comparing mutable job arrays on every poll.
    ///
    /// ⚠️ `copying()` can produce structurally different instances — for example,
    /// toggling `isDimmed` or updating `lastJobCompletedAt` — that this operator
    /// still treats as equal because only `id` is compared. Any caller that needs
    /// to detect snapshot-level field changes (e.g. freeze-state transitions) must
    /// compare fields directly; `==` will not fire for those differences.
    public static func == (lhs: WorkflowActionGroup, rhs: WorkflowActionGroup) -> Bool {
        lhs.id == rhs.id
    }

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

    /// Total job count across all sibling runs.
    public var jobsTotal: Int { jobs.count }

    /// Human-readable job progress fraction, e.g. `"3/5"`. Returns `"—"` while jobs load.
    public var jobProgress: String { jobs.isEmpty ? "—" : "\(jobsDone)/\(jobsTotal)" }

    /// `true` when at least one job in this group has a failure-class conclusion.
    ///
    /// Uses the typed `JobConclusion.isFailure` check (covers `.failure`, `.timedOut`,
    /// `.startupFailure`, `.actionRequired`) rather than raw-string comparison.
    ///
    /// Falls back to run-level conclusions when `jobs` is empty (loading state), mirroring
    /// the same fallback logic used by `conclusion`. This ensures badge/hook callers get
    /// a consistent result before jobs have loaded — a group whose runs already report a
    /// failure-class conclusion will not show a false-negative here during the fetch window.
    ///
    /// TODO: wire into display-layer badge colouring / hook-triggering call sites when
    /// those paths are migrated off their existing inline checks.
    public var hasFailedJob: Bool {
        if !jobs.isEmpty {
            return jobs.contains { $0.jobConclusion?.isFailure == true }
        }
        return runs.contains { $0.conclusion?.isFailure == true }
    }

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
