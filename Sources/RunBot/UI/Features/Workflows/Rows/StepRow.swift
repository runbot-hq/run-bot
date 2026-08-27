// StepRow.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - StepRow

/// A single step row in the workflow hierarchy.
///
/// Mirrors the main-branch `StepRowView` text layout (#2880):
/// status dot · step-name · step-number · Spacer · elapsed.
/// The chevron is dropped — steps no longer navigate to a separate route;
/// selection updates the step-log detail column in place.
struct StepRow: View {
    /// The step to render.
    let step: GitHubStep

    /// The single-line row layout.
    ///
    /// ELAPSED GUARD (mirrors main-branch `StepRowView`) — both required:
    /// `status != "queued"` excludes steps not yet dispatched, and
    /// `startDate != nil` ensures real timing data exists, since
    /// `formatElapsed` returns the sentinel "00:00" (never "") when start is nil.
    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(status: step.rbStatus)
            Text(step.name)
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("#\(step.number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.rbTextTertiary)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .accessibilityLabel("Step \(step.number)")
            Spacer(minLength: 4)
            if step.status != "queued", step.startDate != nil {
                Text(step.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(Color.rbTextTertiary)
                    .fixedSize()
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }
}
