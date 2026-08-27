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

// MARK: - WorkflowActionGroup display helpers

/// UI-layer extensions on `WorkflowActionGroup` for display strings used by the workflow rows.
extension WorkflowActionGroup {
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

    /// The short repo name (without owner prefix), e.g. `"run-bot"` from `"runbot-hq/run-bot"`.
    /// Falls back to the full `repo` string when no slash is present.
    var repoShortName: String {
        repo.components(separatedBy: "/").last ?? repo
    }
}
