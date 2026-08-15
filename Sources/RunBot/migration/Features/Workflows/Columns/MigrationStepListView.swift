// MigrationStepListView.swift
// RunBot

import SwiftUI

/// Steps column — renders step rows or a contextual placeholder.
///
/// `GitHubStep` is not `Identifiable`; `number` is the stable 1-based step index.
struct MigrationStepListView: View {
    let steps: [GitHubStep]
    var selection: MigrationWorkflowSelection

    /// The column layout.
    var body: some View {
        MigrationWorkflowColumn(title: "Steps") {
            if selection.jobID == nil {
                MigrationColumnPlaceholder(
                    title: "Select a job",
                    systemImage: "checklist"
                )
            } else if steps.isEmpty {
                MigrationColumnPlaceholder(
                    title: "No steps",
                    systemImage: "checklist"
                )
            } else {
                List(steps, id: \.number, selection: Binding(
                    get: { selection.stepNumber },
                    set: { selection.selectStep($0) }
                )) { step in
                    MigrationStepRow(step: step)
                        .tag(step.number)
                }
                .listStyle(.plain)
            }
        }
    }
}
