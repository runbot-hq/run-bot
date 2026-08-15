// MigrationStepListView.swift
// RunBot

import SwiftUI

/// Steps pane shell. Prompts for a job selection until step rows are added.
struct MigrationStepListView: View {
    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Steps") {
            MigrationColumnPlaceholder(
                title: "Select a job",
                systemImage: "checklist"
            )
        }
    }
}
