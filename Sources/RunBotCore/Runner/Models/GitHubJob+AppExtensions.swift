// GitHubJob+AppExtensions.swift
// RunBotCore
import Foundation
import GitHubClient

/// RunBotCore-layer extensions on `GitHubJob` that depend on types
/// (`JobStatus`, `JobConclusion`, `RBStatus`) which live in RunBotCore, not GitHubClient.
extension GitHubJob {

    // MARK: Typed accessors

    /// Typed job status derived from the raw `status` string.
    public var jobStatus: JobStatus { JobStatus(rawString: status) }

    /// Typed job conclusion derived from the raw `conclusion` string, or `nil` when running.
    public var jobConclusion: JobConclusion? { conclusion.map { JobConclusion(rawString: $0) } }

    // MARK: Parsed dates

    /// Parsed `startedAt` date, or `nil` when not yet started.
    public var startDate: Date? {
        startedAt.flatMap { parseGitHubDate($0, context: "GitHubJob[\(id)].startedAt") }
    }

    /// Parsed `completedAt` date, or `nil` when still running.
    public var completedDate: Date? {
        completedAt.flatMap { parseGitHubDate($0, context: "GitHubJob[\(id)].completedAt") }
    }

    /// Parsed `createdAt` date, or `nil` when not available.
    public var createdDate: Date? {
        createdAt.flatMap { parseGitHubDate($0, context: "GitHubJob[\(id)].createdAt") }
    }

    // MARK: Display

    /// Human-readable job name used as the display title.
    public var displayTitle: String { name }

    /// Human-readable elapsed duration, e.g. `"02:47"`.
    public var elapsed: String { elapsed(now: Date()) }

    /// Elapsed duration using an injected clock — use in tests for deterministic results.
    public func elapsed(now: Date) -> String {
        formatElapsed(
            start: startDate ?? createdDate,
            end: completedDate,
            isCompleted: jobStatus == .completed || jobConclusion != nil,
            now: now
        )
    }

    /// `true` when this job ran on a self-hosted runner; `nil` when runner name is unknown.
    public var isLocalRunner: Bool? {
        guard let name = runnerName?.lowercased() else { return nil }
        let hosted = ["ubuntu-", "macos-", "windows-", "buildjet-", "depot-", "github actions "]
        return !hosted.contains(where: { name.hasPrefix($0) })
    }

    /// Fraction of steps that have a conclusion (0.0–1.0). `nil` when step list is empty.
    public var progressFraction: Double? {
        guard !steps.isEmpty else { return nil }
        return Double(steps.filter { $0.conclusion != nil }.count) / Double(steps.count)
    }

    /// Canonical display status derived from job conclusion and status.
    public var rbStatus: RBStatus {
        if let conclusion = jobConclusion {
            switch conclusion {
            case .success: return .success
            case .failure: return .failed
            case .skipped: return .skipped
            case .cancelled: return .unknown
            default: return .unknown
            }
        }
        switch jobStatus {
        case .inProgress: return .inProgress
        case .queued: return .queued
        default: return .unknown
        }
    }
}

/// RunBotCore-layer extensions on `GitHubStep` for typed status, dates, and display.
extension GitHubStep {

    /// Typed step status derived from the raw `status` string.
    public var stepStatus: JobStatus { JobStatus(rawString: status) }

    /// Typed step conclusion derived from the raw `conclusion` string, or `nil` when running.
    public var stepConclusion: JobConclusion? { conclusion.map { JobConclusion(rawString: $0) } }

    /// Parsed `startedAt` date, or `nil` when not yet started.
    public var startDate: Date? {
        startedAt.flatMap { parseGitHubDate($0, context: "GitHubStep[\(number)].startedAt") }
    }

    /// Parsed `completedAt` date, or `nil` when still running.
    public var completedDate: Date? {
        completedAt.flatMap { parseGitHubDate($0, context: "GitHubStep[\(number)].completedAt") }
    }

    /// Human-readable elapsed duration.
    public var elapsed: String { elapsed(now: Date()) }

    /// Elapsed duration using an injected clock — use in tests for deterministic results.
    ///
    /// - Note: Uses `start: startDate` only — no `createdDate` fallback. `GitHubStep` has no
    ///   `createdAt` field in the GitHub Actions API response, so there is nothing to fall back to.
    ///   This is intentionally asymmetric with `GitHubJob.elapsed(now:)`, which uses
    ///   `startDate ?? createdDate` because jobs do carry a `created_at` timestamp.
    public func elapsed(now: Date) -> String {
        formatElapsed(start: startDate, end: completedDate, isCompleted: stepConclusion != nil, now: now)
    }

    /// Unicode character summarising step outcome.
    public var conclusionIcon: String {
        switch stepConclusion {
        case .success: return "\u{2713}"
        case .failure: return "\u{2797}"
        case .skipped, .cancelled: return "\u{2298}"
        default: return stepStatus == .inProgress ? "\u{25B6}" : "\u{00B7}"
        }
    }
}

// MARK: - Private ISO 8601 formatters

/// Parses timestamps that include fractional seconds (e.g. `"2026-08-08T16:07:14.123Z"`).
///
/// `nonisolated(unsafe)` suppresses the Swift 6 `#MutableGlobalVariable` diagnostic.
/// Safe because the formatter is read-only after initialisation and
/// `ISO8601DateFormatter` date parsing is thread-safe on a configured instance.
nonisolated(unsafe) private let _iso8601Fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// Parses standard timestamps without fractional seconds (e.g. `"2026-08-08T16:07:14Z"`).
/// GitHub commonly omits fractional seconds; this formatter handles that case.
nonisolated(unsafe) private let _iso8601Standard: ISO8601DateFormatter = ISO8601DateFormatter()

/// Tries fractional-seconds parsing first, then falls back to standard ISO-8601.
///
/// GitHub returns both `"2026-08-08T16:07:14Z"` and `"2026-08-08T16:07:14.000Z"`
/// depending on the endpoint. Using two formatters in sequence ensures both variants
/// parse to a non-nil `Date`.
///
/// The `context` parameter is used only in DEBUG log output to identify the caller.
private func parseGitHubDate(_ value: String, context: String) -> Date? {
    if let date = _iso8601Fractional.date(from: value) {
        #if DEBUG
        log(
            "[TimingTrace][parse] context=\(context) mode=fractional raw=\(value) parsed=\(date)",
            category: .runner
        )
        #endif
        return date
    }
    if let date = _iso8601Standard.date(from: value) {
        #if DEBUG
        log(
            "[TimingTrace][parse] context=\(context) mode=standard raw=\(value) parsed=\(date)",
            category: .runner
        )
        #endif
        return date
    }
    #if DEBUG
    log(
        "[TimingTrace][parse] FAILED context=\(context) raw=\(value)",
        category: .runner
    )
    #endif
    return nil
}
