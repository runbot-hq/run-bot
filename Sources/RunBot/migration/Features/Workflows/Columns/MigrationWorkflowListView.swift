// MigrationWorkflowListView.swift
// RunBot

import SwiftUI

/// Workflows column — renders workflow rows or an empty placeholder.
struct MigrationWorkflowListView: View {
    let workflows: [WorkflowActionGroup]
    var selection: MigrationWorkflowSelection

    /// The column layout.
    var body: some View {
        MigrationWorkflowColumn(title: "Workflows") {
            if workflows.isEmpty {
                MigrationColumnPlaceholder(
                    title: "No workflows",
                    systemImage: "bolt.horizontal.circle",
                    description: "Workflow rows will be added in the next migration step."
                )
            } else {
                List(workflows, selection: Binding(
                    get: { selection.workflowID },
                    set: { selection.selectWorkflow($0) }
                )) { workflow in
                    MigrationWorkflowRow(workflow: workflow)
                        .tag(workflow.id)
                }
                .listStyle(.plain)
            }
        }
    }
}
