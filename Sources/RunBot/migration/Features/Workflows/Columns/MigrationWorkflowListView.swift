// MigrationWorkflowListView.swift
// RunBot

import SwiftUI

/// Workflows pane shell. Displays an empty placeholder until workflow rows are added.
struct MigrationWorkflowListView: View {
    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Workflows") {
            ContentUnavailableView(
                "No workflows",
                systemImage: "bolt.horizontal.circle",
                description: Text(
                    "Workflow rows will be added in the next migration step."
                )
            )
        }
    }
}
