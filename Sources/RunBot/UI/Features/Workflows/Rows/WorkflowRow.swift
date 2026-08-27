// WorkflowRow.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - WorkflowRow

/// A single workflow row in the workflow hierarchy.
///
/// Mirrors the main-branch `ActionRowView` text layout (#2880):
/// status dot · repo-name · commit-title · branch · Spacer
/// · time-ago · completed-duration · jobs-progress.
/// The animated donut is replaced by the flat `StatusIndicator` dot.
struct WorkflowRow: View {
    /// The workflow to render.
    let workflow: WorkflowActionGroup

    /// The single-line row layout.
    var body: some View {
        HStack(spacing: 6) {
            StatusIndicator(status: workflow.rbStatus)
            Text(workflow.repoShortName)
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(workflow.title)
                .font(.system(.caption, design: .monospaced, weight: .semibold))
                .foregroundColor(workflow.isDimmed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: RBMetrics.actionRowTitleMaxWidth, alignment: .leading)
                .help(workflow.title)
                .layoutPriority(1)
            // Branch — middle-truncated, full value available through the tooltip;
            // hidden when nil, matching main-branch behaviour (#1194, #2610).
            if let branch = workflow.headBranch {
                Text(branch)
                    .font(RBFont.mono)
                    .foregroundColor(Color.rbTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: RBMetrics.actionRowBranchMaxWidth, alignment: .leading)
                    .help(branch)
                    .layoutPriority(0)
            }
            Spacer(minLength: 4)
            metaTrailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// Trailing metadata group: time-ago · completed-duration · jobs-progress.
    ///
    /// Mirrors the main-branch trailing metadata: `.fixedSize` prevents members
    /// being compressed to zero and `.layoutPriority(2)` lets the group win
    /// horizontal space before the title and branch text.
    @ViewBuilder private var metaTrailing: some View {
        let relativeStart = workflow.firstJobStartedAt ?? workflow.createdAt
        let duration = workflow.completedDuration
        let hasProgress = !workflow.jobs.isEmpty

        HStack(spacing: RBSpacing.xs) {
            if let relativeStart {
                Text(RelativeTimeFormatter.string(from: relativeStart))
                    .font(RBFont.mono)
                    .foregroundStyle(Color.rbTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if relativeStart != nil, duration != nil || hasProgress {
                metadataSeparator
            }

            // Completed-duration label: only for terminal workflows with valid
            // timestamps. Active, queued, and loading rows show nothing here.
            if let duration {
                Text(WorkflowDurationFormatter.string(from: duration))
                    .font(RBFont.mono)
                    .monospacedDigit()
                    .foregroundStyle(Color.rbTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if duration != nil, hasProgress {
                metadataSeparator
            }

            if hasProgress {
                Text(workflow.jobProgress)
                    .font(RBFont.mono)
                    .monospacedDigit()
                    .foregroundStyle(Color.rbTextSecondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    /// Decorative centered-dot separator between metadata values.
    private var metadataSeparator: some View {
        Text("·")
            .font(RBFont.mono)
            .foregroundStyle(Color.rbTextTertiary)
            .accessibilityHidden(true)
    }
}
