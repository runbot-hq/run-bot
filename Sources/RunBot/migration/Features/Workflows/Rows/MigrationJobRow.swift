// MigrationJobRow.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationJobRow

/// A single job row in the workflow hierarchy.
///
/// Two lines: runner-type icon and job title (line 1), elapsed time and step
/// progress (line 2). The numeric job ID is not displayed.
/// All text uses `.lineLimit(1)` so the pane minimum width is never widened.
struct MigrationJobRow: View {
    /// The job to render.
    let job: ActiveJob

    /// SF Symbol indicating a self-hosted (local) or GitHub-hosted (cloud) runner.
    private var runnerSymbolName: String {
        job.isLocalRunner == true ? "desktopcomputer" : "cloud"
    }

    /// Step progress text, or nil when the step list is empty.
    private var stepProgress: String? {
        guard !job.steps.isEmpty else { return nil }
        let done = job.steps.filter { $0.conclusion != nil }.count
        return "\(done)/\(job.steps.count) steps"
    }

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MigrationStatusIndicator(status: job.rbStatus)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: runnerSymbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    Text(job.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

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
