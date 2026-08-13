// WorkflowActionGroup+Progress.swift
// RunBot
// Extracted from PanelProgressViews.swift during dead-code cleanup (removed PieProgressDot).
import Foundation
import RunBotCore
import SwiftUI

// MARK: - RelativeTimeFormatter
/// Formats a `Date` into a compact relative string like `"3m ago"`, `"1h ago"`, `"2d ago"`.
///
/// Intended for one-off formatting in row views; not observation-based —
/// callers should refresh on a suitable timer tick.
enum RelativeTimeFormatter {
    /// Returns a short relative string for the interval between `date` and `now`.
    /// Returns `"just now"` for intervals < 60 s, `"Nm ago"` < 60 min,
    /// `"Nh ago"` < 48 h, and `"Nd ago"` otherwise.
    static func string(from date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60:      return "just now"
        case ..<3_600:   return "\(Int(seconds / 60))m ago"
        case ..<172_800: return "\(Int(seconds / 3_600))h ago"
        default:         return "\(Int(seconds / 86_400))d ago"
        }
    }
}

// MARK: - WorkflowActionGroup progress helpers

/// UI-layer extensions on `WorkflowActionGroup` for deriving progress fractions
/// and display strings used by the panel's action rows.
extension WorkflowActionGroup {

    /// Returns the overall completion fraction (0.0–1.0) across all jobs in the group.
    ///
    /// Calculated as the ratio of completed steps to total steps. Returns `nil`
    /// when no steps are present so callers can suppress progress indicators entirely.
    var progressFraction: Double? {
        let steps = jobs.flatMap { $0.steps }
        guard !steps.isEmpty else { return nil }
        // GitHubStep.status and .conclusion are raw Strings — compare against literals.
        let done = steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
        return Double(done) / Double(steps.count)
    }

    /// Elapsed time as a `mm:ss` string, computed from `firstJobStartedAt` to
    /// `lastJobCompletedAt` (completed runs) or `Date()` (active runs).
    ///
    /// Returns an empty string when no job has started yet.
    /// Use `RelativeTimeFormatter.string(from: firstJobStartedAt)` for the time-ago display.
    ///
    /// - Note: `isCompleted` only affects `formatElapsed`'s nil-`start` sentinel path
    ///   (choosing `"--:--"` vs `"00:00"`). Since `start` is already unwrapped by the
    ///   guard above, the argument has no runtime effect here. It is passed anyway so
    ///   that the call site stays consistent with `WorkflowActionGroup.elapsed` in
    ///   `WorkflowActionGroup.swift`, and would behave correctly if the guard were
    ///   ever removed in favour of a nil-delegating path.
    var elapsed: String {
        guard let start = firstJobStartedAt else { return "" }
        return formatElapsed(
            start: start,
            end: lastJobCompletedAt,
            isCompleted: groupStatus == .completed
        )
    }

    /// The start date of the earliest job in the group, or `nil` if none has started.
    var firstJobStartedAt: Date? {
        jobs.compactMap { $0.startDate }.min()
    }

    /// `true` when the group is completed and its conclusion is neither success nor a failure-class
    /// outcome (i.e. not `.success` and `isFailure` is `false`).
    ///
    /// `.cancelled` and `.skipped` satisfy both conditions (not success, not isFailure) and are
    /// **intentionally dimmed** — they represent terminal-but-neutral states that share the
    /// grey visual tier with `.neutral`, `.stale`, `.unknown`, and `nil`.
    ///
    /// `.loading` is correctly excluded by the `groupStatus == .completed` guard —
    /// a group in the fetch window is never dimmed.
    var isDimmed: Bool {
        guard groupStatus == .completed else { return false }
        return conclusion != .success && conclusion?.isFailure != true
    }

    /// `true` when the group originated from a self-hosted (local) runner.
    ///
    /// Derived from the first job's runner name; returns `nil` when ambiguous.
    var isLocalGroup: Bool? {
        guard let first = jobs.first else { return nil }
        return first.runnerName?.lowercased().contains("self-hosted") == true
    }

    /// The short repo name (without owner prefix), e.g. `"run-bot"` from `"runbot-hq/run-bot"`.
    /// Falls back to the full `repo` string when no slash is present.
    var repoShortName: String {
        repo.components(separatedBy: "/").last ?? repo
    }
}

// MARK: - ActiveJob + progressFraction
/// Adds a pie-progress fraction property to `ActiveJob` for use with `DonutStatusView`.
extension ActiveJob {
    /// Radial fill fraction (0.0–1.0). Returns `nil` while queued or when no steps are available.
    var progressFraction: Double? {
        switch jobStatus {
        case .queued: return nil
        case .completed: return 1.0
        default:
            guard !steps.isEmpty else { return nil }
            // GitHubStep.conclusion is a raw String? — nil means not yet finished.
            let done = steps.filter { $0.conclusion != nil }.count
            let fraction = Double(done) / Double(steps.count)
            return min(max(fraction, 0.0), 1.0)
        }
    }
}
