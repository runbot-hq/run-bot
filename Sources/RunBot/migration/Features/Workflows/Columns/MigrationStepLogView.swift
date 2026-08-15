// MigrationStepLogView.swift
// RunBot

import GitHubClient
import SwiftUI

/// Step-log pane — confirms end-to-end selection without log rendering.
///
/// Full log rendering (ANSI/Markdown, toolbar, badges) is introduced
/// in a later migration step.
struct MigrationStepLogView: View {
    /// The currently selected step, or `nil` when none is selected.
    let selectedStep: GitHubStep?

    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Step log") {
            if let step = selectedStep {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.name)
                        .font(.headline)
                        .lineLimit(2)
                    Text("Log rendering will be added in a later migration step.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                MigrationColumnPlaceholder(
                    title: "Select a step",
                    systemImage: "doc.plaintext"
                )
            }
        }
    }
}
