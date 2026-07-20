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
    ///
    /// - Note: Delegates to `raw.elapsed`, which reads `raw.jobStatus` and `raw.jobConclusion`
    ///   directly — not the override-aware `jobStatus`/`jobConclusion` computed properties on
    ///   `ActiveJob`. In practice this is safe because `asCompleted()` always writes a
    ///   `completedAt` date into `raw` (falling back to its `fallbackDate` argument when the
    ///   API value is nil), so `raw.elapsed` returns a fixed `mm:ss` string regardless of
    ///   `statusOverride`. If `asCompleted()` ever stops guaranteeing a non-nil `completedAt`,
    ///   this property should be rewritten to call `formatElapsed` directly like `elapsed(now:)`.
    public var elapsed: String { raw.elapsed }

    /// Elapsed duration using an injected clock — use in tests for deterministic results.
    ///
    /// Uses the override-aware `jobStatus` and `jobConclusion` computed properties rather
    /// than delegating to `raw.elapsed(now:)`, so a job frozen via `asCompleted()` (which
    /// sets `statusOverride = .completed`) is correctly treated as completed even when
    /// `raw.completedDate` is nil.
    public func elapsed(now: Date) -> String {
        formatElapsed(
            start: startDate ?? createdDate,
            end: completedDate,
            isCompleted: jobStatus == .completed || jobConclusion != nil,
            now: now
        )
    }

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
        withUpdatedRaw(raw.copying { $0.runnerName = newValue })
    }

    /// Returns a copy with `startedAt` replaced.
    public func copying(startedAt newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying { $0.startedAt = newValue })
    }

    /// Returns a copy with `completedAt` replaced.
    public func copying(completedAt newValue: String?) -> ActiveJob {
        withUpdatedRaw(raw.copying { $0.completedAt = newValue })
    }

    /// Returns a copy with `steps` replaced.
    public func copying(steps newValue: [GitHubStep]) -> ActiveJob {
        withUpdatedRaw(raw.copying { $0.steps = newValue })
    }

    /// Returns a copy with `conclusion` replaced.
    public func copying(conclusion newValue: JobConclusion?) -> ActiveJob {
        withUpdatedRaw(raw.copying { $0.conclusion = newValue?.rawValue })
    }

    // MARK: asCompleted

    /// Returns a completed, dimmed copy of this job.
    ///
    /// Sets `statusOverride` to `.completed` and `isDimmed` to `true`.
    /// When `raw.completedAt` is `nil`, `fallbackDate` is ISO-8601-encoded and
    /// written into `raw` so `completedDate` returns a non-nil `Date`.
    public func asCompleted(at fallbackDate: Date) -> ActiveJob {
        let updatedRaw: GitHubJob
        if raw.completedAt == nil {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            updatedRaw = raw.copying { $0.completedAt = iso.string(from: fallbackDate) }
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
