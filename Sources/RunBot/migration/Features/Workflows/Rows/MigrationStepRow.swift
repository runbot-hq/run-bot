// MigrationStepRow.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - MigrationStepRow

/// A single row in the Steps column.
///
/// Two lines: step title (line 1), step number and elapsed time (line 2).
/// Elapsed is omitted for queued or unstarted steps.
struct MigrationStepRow: View {
    /// The step to render.
    let step: GitHubStep

    /// Elapsed text only for started steps; nil for queued/waiting.
    private var elapsedText: String? {
        guard step.startDate != nil else { return nil }
        let text = step.elapsed
        return text.isEmpty ? nil : text
    }

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            MigrationStatusIndicator(status: step.rbStatus)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                MigrationRowMetadata(
                    values: [
                        "step \(step.number)",
                        elapsedText
                    ]
                )
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
