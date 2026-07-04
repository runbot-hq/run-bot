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
    let statusOverride: JobStatus?
    let conclusionOverride: JobConclusion?

    public var id: Int { raw.id }

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
    public var name: String        { raw.name }
    public var htmlUrl: String?    { raw.htmlUrl }
    public var runnerName: String? { raw.runnerName }
    public var steps: [GitHubStep] { raw.steps }

    // MARK: Overridable fields
    public var jobStatus: JobStatus          { statusOverride ?? raw.jobStatus }
    public var jobConclusion: JobConclusion? { conclusionOverride ?? raw.jobConclusion }

    // MARK: Forwarded computed properties (defined on GitHubJob extension — Step 4)
    public var elapsed: String           { raw.elapsed }
    public var displayTitle: String      { raw.displayTitle }
    public var isLocalRunner: Bool?      { raw.isLocalRunner }
    public var progressFraction: Double? { raw.progressFraction }
    public var rbStatus: RBStatus        { raw.rbStatus }
    public var startDate: Date?          { raw.startDate }
    public var completedDate: Date?      { raw.completedDate }
    public var createdDate: Date?        { raw.createdDate }

    // MARK: copying — app-only fields
    public func copying(isDimmed v: Bool) -> ActiveJob {
        ActiveJob(raw: raw, isDimmed: v, scope: scope,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }
    public func copying(scope v: String?) -> ActiveJob {
        ActiveJob(raw: raw, isDimmed: isDimmed, scope: v,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }

    // MARK: copying — GitHubJob fields (via withUpdatedRaw)
    public func withUpdatedRaw(_ r: GitHubJob) -> ActiveJob {
        ActiveJob(raw: r, isDimmed: isDimmed, scope: scope,
                  statusOverride: statusOverride, conclusionOverride: conclusionOverride)
    }
    public func copying(runnerName v: String?) -> ActiveJob  { withUpdatedRaw(raw.copying(runnerName: v)) }
    public func copying(startedAt v: String?) -> ActiveJob   { withUpdatedRaw(raw.copying(startedAt: v)) }
    public func copying(completedAt v: String?) -> ActiveJob { withUpdatedRaw(raw.copying(completedAt: v)) }
    public func copying(createdAt v: String?) -> ActiveJob   { withUpdatedRaw(raw.copying(createdAt: v)) }
    public func copying(steps v: [GitHubStep]) -> ActiveJob  { withUpdatedRaw(raw.copying(steps: v)) }
    public func copying(conclusion v: JobConclusion?) -> ActiveJob {
        withUpdatedRaw(raw.copying(conclusion: v?.rawValue))
    }

    // MARK: asCompleted
    /// Returns a completed, dimmed copy of this job using override slots.
    public func asCompleted(at fallbackDate: Date) -> ActiveJob {
        // fallbackDate is not stored — completedAt lives in raw (String).
        // Callers that need a concrete completedAt string should use copying(completedAt:) first.
        ActiveJob(
            raw: raw,
            isDimmed: true,
            scope: scope,
            statusOverride: .completed,
            conclusionOverride: conclusionOverride ?? raw.jobConclusion ?? .neutral
        )
    }
}
