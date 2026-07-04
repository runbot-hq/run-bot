// GitHubJob+AppExtensions.swift
// RunBotCore

import Foundation
import GitHubClient

/// RunBotCore-layer extensions on `GitHubJob` that depend on types
/// (`JobStatus`, `JobConclusion`, `RBStatus`) which live in RunBotCore, not GitHubClient.
extension GitHubJob {

    // MARK: Typed accessors

    // JobStatus and JobConclusion live in RunBotCore — not visible to GitHubClient.
    // Both use init(rawString:) — same pattern as RunnerStatus.

    /// Typed job status derived from the raw `status` string.
    public var jobStatus: JobStatus { JobStatus(rawString: status) }
    /// Typed job conclusion derived from the raw `conclusion` string, or `nil` when running.
    public var jobConclusion: JobConclusion? { conclusion.map { JobConclusion(rawString: $0) } }

    // MARK: Parsed dates

    // Uses a module-private ISO8601DateFormatter (see bottom of file).
    // Same formatter config as the existing makeActiveJob(from:iso:isDimmed:) function.

    /// Parsed `startedAt` date, or `nil` when not yet started.
    public var startDate: Date? { startedAt.flatMap { _iso8601.date(from: $0) } }
    /// Parsed `completedAt` date, or `nil` when still running.
    public var completedDate: Date? { completedAt.flatMap { _iso8601.date(from: $0) } }
    /// Parsed `createdAt` date, or `nil` when not available.
    public var createdDate: Date? { createdAt.flatMap { _iso8601.date(from: $0) } }

    // MARK: Display

    /// Human-readable job name used as the display title.
    public var displayTitle: String { name }

    /// Human-readable elapsed duration, e.g. `"02:47"`.
    /// Matches existing ActiveJob.elapsed logic exactly.
    public var elapsed: String {
        formatElapsed(
            start: startDate ?? createdDate,
            end: completedDate,
            isCompleted: jobStatus == .completed || jobConclusion != nil
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

    /// Canonical display status — matches existing ActiveJob.rbStatus logic exactly.
    public var rbStatus: RBStatus {
        if let conclusion = jobConclusion {
            switch conclusion {
            case .success: return .success
            case .failure: return .failed
            case .cancelled, .skipped: return .unknown
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
    public var startDate: Date? { startedAt.flatMap { _iso8601.date(from: $0) } }
    /// Parsed `completedAt` date, or `nil` when still running.
    public var completedDate: Date? { completedAt.flatMap { _iso8601.date(from: $0) } }
    /// Human-readable elapsed duration — matches existing JobStep.elapsed logic exactly.
    public var elapsed: String {
        formatElapsed(start: startDate, end: completedDate, isCompleted: stepConclusion != nil)
    }
    /// Unicode character summarising step outcome — matches existing JobStep.conclusionIcon.
    public var conclusionIcon: String {
        switch stepConclusion {
        case .success:            return "\u{2713}"
        case .failure:            return "\u{2797}"
        case .skipped, .cancelled: return "\u{2298}"
        default: return stepStatus == .inProgress ? "\u{25B6}" : "\u{00B7}"
        }
    }
}

// MARK: - Private ISO8601 formatter

// Module-private — same config as the formatter passed into makeActiveJob(from:iso:isDimmed:).
private let _iso8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
