// MigrationJobRow.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationJobRow

/// A single job row in the workflow hierarchy.
///
/// Mirrors the main-branch `JobRowCard` header text layout (#2880):
/// status dot · runner-type-icon · job-name · job-id · Spacer
/// · elapsed · steps-progress.
struct MigrationJobRow: View {
    /// The job to render.
    let job: ActiveJob

    /// SF Symbol indicating a self-hosted (local) or GitHub-hosted (cloud) runner.
    private var runnerSymbolName: String {
        job.isLocalRunner == true ? "desktopcomputer" : "cloud"
    }

    /// Total number of steps in this job.
    private var totalSteps: Int { job.steps.count }

    /// Number of completed steps in this job.
    ///
    /// Both conditions are intentional (mirrors main-branch `JobRowCard`):
    /// `conclusion != nil` marks a finished step, and `status == "completed"`
    /// is the defensive fallback for API responses where conclusion is
    /// temporarily absent but the step is no longer running.
    private var completedSteps: Int {
        job.steps.filter { $0.conclusion != nil || $0.status == "completed" }.count
    }

    /// The single-line row layout.
    var body: some View {
        HStack(spacing: 6) {
            MigrationStatusIndicator(status: job.rbStatus)
            Image(systemName: runnerSymbolName)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(job.name)
                .font(RBFont.mono)
                .foregroundColor(job.isDimmed ? Color.rbTextTertiary : Color.rbTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("#\(job.id)")
                .font(RBFont.mono)
                .foregroundColor(Color.rbTextTertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 4)
            metaTrailing
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
    }

    /// Trailing metadata group: elapsed · steps-progress.
    ///
    /// The elapsed guard mirrors `GitHubJob.elapsed(now:)`'s own start logic —
    /// the label is shown iff `startDate` or `createdDate` is non-nil, meaning
    /// the model has real timing data (#2129). Do not replace with an
    /// `elapsed.isEmpty` check: `formatElapsed` never returns an empty string.
    @ViewBuilder private var metaTrailing: some View {
        let showsElapsed = job.startDate != nil || job.createdDate != nil
        let showsStepProgress = totalSteps > 0

        HStack(spacing: RBSpacing.xs) {
            if showsElapsed {
                Text(job.elapsed)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.rbTextTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Job duration")
            }

            if showsElapsed, showsStepProgress {
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(Color.rbTextTertiary)
                    .accessibilityHidden(true)
            }

            if showsStepProgress {
                Text("\(completedSteps)/\(totalSteps)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.rbTextTertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
