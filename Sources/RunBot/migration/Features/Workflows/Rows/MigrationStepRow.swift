// MigrationStepRow.swift
// RunBot

import SwiftUI

/// A single row in the Steps column.
///
/// Displays status indicator, step name, and elapsed time.
/// Elapsed is omitted for queued/unstarted steps — mirrors the existing
/// `InlineJobRowsView` timing guard.
struct MigrationStepRow: View {
    /// The step to render.
    let step: GitHubStep

    /// Elapsed text only for started steps; nil for queued/waiting.
    private var elapsedText: String? {
        guard step.startDate != nil else { return nil }
        let elapsedText = step.elapsed
        return elapsedText.isEmpty ? nil : elapsedText
    }

    /// The row layout.
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            MigrationStatusIndicator(status: step.rbStatus)

            VStack(alignment: .leading, spacing: 3) {
                Text(step.name)
                    .font(.headline)
                    .lineLimit(2)

                MigrationRowMetadata(values: [elapsedText])
            }
        }
        .padding(.vertical, 6)
        .contentShape(.rect)
    }
}
