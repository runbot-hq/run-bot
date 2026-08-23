// StepLogView+StatusDisplay.swift
// RunBot
import RunBotCore
import SwiftUI

/// Status-display computed properties for `StepLogView`.
///
/// Extracted to keep `StepLogView.swift` under the `file_length` lint limit.
extension StepLogContentView {

    /// Human-readable label derived from the step's conclusion and status.
    ///
    /// Maps `GitHubStep.conclusion` (raw `String?`) through `JobConclusion` for
    /// display, falling back to a running/queued label when conclusion is absent.
    var stepStatusLabel: String {
        guard let raw = step.conclusion else {
            return step.status == "in_progress" ? "▶ running" : "· queued"
        }
        switch JobConclusion(rawString: raw) {
        case .success:                          return "✓ success"
        case .failure:                          return "✗ failure"
        case .cancelled:                        return "⊘ cancelled"
        case .neutral:                          return "· neutral"
        case .skipped:                          return "⊘ skipped"
        case .timedOut:                         return "✗ timed out"
        case .actionRequired:                   return "! action required"
        case .stale:                            return "· stale"
        case .startupFailure:                   return "✗ startup failure"
        case .unknown(let raw):                 return "· \(raw)"
        }
    }

    /// Foreground colour for the step status label.
    ///
    /// Maps `GitHubStep.conclusion` (raw `String?`) through `JobConclusion` for
    /// colour selection, falling back to warning/secondary colours when absent.
    var stepStatusColor: Color {
        guard let raw = step.conclusion else {
            return step.status == "in_progress" ? Color.rbWarning : Color.rbTextSecondary
        }
        switch JobConclusion(rawString: raw) {
        case .success:                          return Color.rbSuccess
        case .failure, .timedOut,
             .actionRequired, .startupFailure: return Color.rbDanger
        case .skipped, .cancelled, .neutral, .stale,
             .unknown:                         return Color.rbTextSecondary
        }
    }
}
