// ActiveJob.swift
// RunBotCore

import Foundation
import GitHubClient

// MARK: - ActiveJob

/// A live or recently-completed GitHub Actions job visible in the panel.
///
/// Wraps an immutable `GitHubJob` from `GitHubClient` and adds two pieces of
/// app-only state (`isDimmed`, `scope`) plus override slots used by `asCompleted`
/// to freeze status/conclusion without mutating the underlying API value.
public struct ActiveJob: Identifiable, Equatable, Sendable {

    // MARK: Core

    /// The raw API job from GitHubClient.
    public let raw: GitHubJob
    /// `true` for recently-completed jobs shown as faded history entries.
    public let isDimmed: Bool
    /// The repo or org scope string this job belongs to.
    /// Always `nil` at decode time — injected post-fetch by `RunnerStore`.
    public let scope: String?

    // Override slots — used only by asCompleted to freeze status/conclusion.
    // nil means "use the value from raw".
    /// Overrides `raw.jobStatus` when set. `nil` defers to the raw value.
    let statusOverride: JobStatus?
    /// Overrides `raw.jobConclusion` when set. `nil` defers to the raw value.
    let conclusionOverride: JobConclusion?

    /// Stable ID forwarded from `raw`.
    public var id: Int { raw.id }

    // MARK: Designated init

    /// Creates an `ActiveJob` wrapping a raw `GitHubJob`.
    public init(
        raw: GitHubJob,
        isDimmed: Bool = false,
        scope: String? = nil,
        statusOverride: JobStatus? = nil,
        conclusionOverride: JobConclusion? = nil
    ) {
        self.raw = raw
        self.isDimmed = isDimmed
        self.scope = scope
        self.statusOverride = statusOverride
        self.conclusionOverride = conclusionOverride
    }

    // MARK: Convenience init (flat fields)

    /// Creates an `ActiveJob` from individual field values.
    ///
    /// This initialiser constructs the internal `GitHubJob` from flat
    /// parameters so call-sites that pre-date the `raw:` refactor continue to
    /// compile unchanged.
    ///
    /// - Parameters:
    ///   - id:          The job's GitHub numeric ID.
    ///   - name:        Display name of the job.
    ///   - status:      Job status string (e.g. `"queued"`, `"in_progress"`, `"completed"`).
    ///                  Accepts a raw `String` **or** a `JobStatus` value via
    ///                  `ExpressibleByStringLiteral` conformance.
    ///   - conclusion:  Optional conclusion string (e.g. `"success"`, `"failure"`).
    ///                  Accepts a raw `String` **or** a `JobConclusion` value.
    ///   - htmlUrl:     Optional URL linking to the job on GitHub.
    ///   - runnerName:  Optional runner name (used to determine `isLocalRunner`).
    ///   - startedAt:   Optional job start `Date`; encoded to ISO-8601 string.
    ///   - completedAt: Optional job completion `Date`; encoded to ISO-8601 string.
    ///   - createdAt:   Optional job creation `Date`; encoded to ISO-8601 string.
    ///   - steps:       Array of `GitHubStep` values (aliased as `JobStep`).
    ///   - isDimmed:    Whether the job is displayed as a faded history entry.
    ///   - scope:       Repo/org scope string, injected post-fetch.
    public init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        htmlUrl: String? = nil,
        runnerName: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        steps: [GitHubStep] = [],
        isDimmed: Bool = false,
        scope: String? = nil
    ) {
        let iso = ISO8601DateFormatter()
        let raw = GitHubJob(
            id: id,
            name: name,
            status: status,
            conclusion: conclusion,
            htmlUrl: htmlUrl,
            runnerName: runnerName,
            startedAt: startedAt.map { iso.string(from: $0) },
            completedAt: completedAt.map { iso.string(from: $0) },
            createdAt: createdAt.map { iso.string(from: $0) },
            steps: steps
        )
        self.init(raw: raw, isDimmed: isDimmed, scope: scope)
    }

    // MARK: Forwarded API fields

    /// Job display name forwarded from `raw.name`.
    public var name: String { raw.name }
    /// GitHub web URL forwarded from `raw.htmlUrl`.
    public var htmlUrl: String? { raw.htmlUrl }
    /// Runner name forwarded from `raw.runnerName`.
    public var runnerName: String? { raw.runnerName }
    /// Steps array forwarded from `raw.steps`.
    public var steps: [GitHubStep] { raw.steps }

    // MARK: Overridable fields

    /// Effective job status — uses `statusOverride` when set, else `raw.jobStatus`.
    public var jobStatus: JobStatus { statusOverride ?? raw.jobStatus }
    /// Effective job conclusion — uses `conclusionOverride` when set, else `raw.jobConclusion`.
    public var jobConclusion: JobConclusion? { conclusionOverride ?? raw.jobConclusion }

    // MARK: Forwarded computed properties (defined on GitHubJob extension)

    /// Human-readable elapsed duration forwarded from `raw.elapsed`.
    public var elapsed: String { raw.elapsed }
    /// Display title forwarded from `raw.displayTitle`.
    public var displayTitle: String { raw.displayTitle }
    /// Whether the job ran on a local runner, forwarded from `raw.isLocalRunner`.
    public var isLocalRunner: Bool? { raw.isLocalRunner }
    /// Progress fraction (0–1) forwarded from `raw.progressFraction`.
    public var progressFraction: Double? { raw.progressFraction }
    /// Canonical display status forwarded from `raw.rbStatus`.
    public var rbStatus: RBStatus { raw.rbStatus }
    /// Parsed start date forwarded from `raw.startDate`.
    public var startDate: Date? { raw.startDate }
    /// Parsed completion date forwarded from `raw.completedDate`.
    public var completedDate: Date? { raw.completedDate }
    /// Parsed creation date forwarded from `raw.createdDate`.
    public var createdDate: Date? { raw.createdDate }

    // MARK: copying — app-only fields

    /// Returns a copy with `isDimmed` replaced.
    public func copying(isDimmed newValue: Bool) -> ActiveJob {
        ActiveJob(raw: raw, isDimmed: newValue, scope: scope,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }

    /// Returns a copy with `scope` replaced.
    public func copying(scope newValue: String?) -> ActiveJob {
        ActiveJob(raw: raw, isDimmed: isDimmed, scope: newValue,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }

    // MARK: copying — GitHubJob fields (via withUpdatedRaw)

    /// Returns a copy with `raw` replaced by `job`.
    public func withUpdatedRaw(_ job: GitHubJob) -> ActiveJob {
        ActiveJob(raw: job, isDimmed: isDimmed, scope: scope,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }

    /// Returns a copy with `runnerName` replaced.
    public func copying(runnerName newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying(runnerName: newValue))
    }

    /// Returns a copy with `startedAt` replaced.
    public func copying(startedAt newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying(startedAt: newValue))
    }

    /// Returns a copy with `completedAt` replaced.
    public func copying(completedAt newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying(completedAt: newValue))
    }

    /// Returns a copy with `createdAt` replaced.
    public func copying(createdAt newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying(createdAt: newValue))
    }

    /// Returns a copy with `steps` replaced.
    public func copying(steps newValue: [GitHubStep]) -> ActiveJob {
        withUpdatedRaw(raw.copying(steps: newValue))
    }

    /// Returns a copy with `conclusion` replaced.
    public func copying(conclusion newValue: JobConclusion?) -> ActiveJob {
        withUpdatedRaw(raw.copying(conclusion: newValue?.rawValue))
    }

    // MARK: asCompleted

    /// Returns a completed, dimmed copy of this job.
    ///
    /// The `statusOverride` is set to `.completed` and `isDimmed` to `true`.
    /// If `raw.completedAt` is `nil`, `fallbackDate` is encoded as an ISO-8601
    /// string and written into `raw` so that `completedDate` returns a non-nil
    /// `Date` for callers that depend on it (e.g. `ActiveJobAsCompletedTests`).
    public func asCompleted(at fallbackDate: Date) -> ActiveJob {
        // Write fallbackDate into raw when the API hasn't provided a completedAt.
        let updatedRaw: GitHubJob
        if raw.completedAt == nil {
            let iso = ISO8601DateFormatter()
            updatedRaw = raw.copying(completedAt: iso.string(from: fallbackDate))
        } else {
            updatedRaw = raw
        }
        return ActiveJob(
            raw: updatedRaw,
            isDimmed: true,
            scope: scope,
            statusOverride: .completed,
            conclusionOverride: conclusionOverride ?? raw.jobConclusion ?? .neutral
        )
    }
}

// MARK: - JobStep typealias

/// `JobStep` is a source-compatibility alias for `GitHubStep`.
///
/// Legacy test code that pre-dates the `GitHubClient` extraction uses
/// `JobStep` as the step type. The alias lets those files compile without
/// modification while the rest of the codebase migrates to `GitHubStep`.
public typealias JobStep = GitHubStep
