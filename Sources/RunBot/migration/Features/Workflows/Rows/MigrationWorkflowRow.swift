// MigrationWorkflowRow.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationWorkflowRow

/// A single row in the Workflows column.
///
/// Three lines: workflow title (line 1), repository and branch (line 2),
/// elapsed time, start date, and progress (line 3).
/// All text uses `.lineLimit(1)` so the pane minimum width is never widened.
struct MigrationWorkflowRow: View {
    /// The workflow to render.
    let workflow: WorkflowActionGroup

    /// Compact start-date string derived from the earliest available timestamp.
    private var startDateText: String? {
        guard let date = workflow.firstJobStartedAt ?? workflow.createdAt else { return nil }
        return MigrationRowDateFormatter.shared.string(from: date)
    }

    /// Job progress with explicit 'jobs' suffix, e.g. "5/6 jobs".
    private var jobProgressText: String? {
        guard !workflow.jobs.isEmpty else { return nil }
        return workflow.jobProgress + " jobs"
    }

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MigrationStatusIndicator(status: workflow.groupStatus.rbStatus)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(workflow.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                MigrationRowMetadata(
                    values: [
                        workflow.repoShortName,
                        workflow.headBranch
                    ]
                )

                MigrationRowMetadata(
                    values: [
                        workflow.elapsed.isEmpty ? nil : workflow.elapsed,
                        startDateText,
                        jobProgressText
                    ]
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
