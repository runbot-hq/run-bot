// MigrationWorkflowRow.swift
// RunBot

import RunBotCore
import SwiftUI

/// A single row in the Workflows column.
///
/// Displays status indicator, repository short name, workflow title,
/// branch, elapsed time, and job progress. Uses `.lineLimit(1)` on
/// all text so the pane minimum width is never widened by long titles.
struct MigrationWorkflowRow: View {
    /// The workflow to render.
    let workflow: WorkflowActionGroup

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MigrationStatusIndicator(status: workflow.groupStatus.rbStatus)

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.repoShortName)
                    .font(.headline)
                    .lineLimit(1)

                Text(workflow.title)
                    .font(.subheadline)
                    .lineLimit(1)

                MigrationRowMetadata(
                    values: [
                        workflow.headBranch,
                        workflow.elapsed.isEmpty ? nil : workflow.elapsed,
                        workflow.jobs.isEmpty ? nil : workflow.jobProgress
                    ]
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
