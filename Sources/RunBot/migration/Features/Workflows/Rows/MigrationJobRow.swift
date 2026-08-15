// MigrationJobRow.swift
// RunBot

import SwiftUI

/// A single row in the Jobs column.
///
/// Displays status indicator, job display title, job ID, elapsed time,
/// and step progress. Uses `.lineLimit(1)` on all text so the pane
/// minimum width is never widened by long job names.
struct MigrationJobRow: View {
    /// The job to render.
    let job: ActiveJob

    /// Step progress text, or nil when the step list is empty.
    private var stepProgress: String? {
        guard !job.steps.isEmpty else { return nil }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return "\(done)/\(job.steps.count) steps"
    }

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MigrationStatusIndicator(status: job.rbStatus)

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayTitle)
                    .font(.headline)
                    .lineLimit(1)

                Text("#\(job.id)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                MigrationRowMetadata(
                    values: [
                        job.elapsed.isEmpty ? nil : job.elapsed,
                        stepProgress
                    ]
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
