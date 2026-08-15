// MigrationJobListView.swift
// RunBot

import SwiftUI

/// Jobs pane shell. Prompts for a workflow selection until job rows are added.
struct MigrationJobListView: View {
    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Jobs") {
            ContentUnavailableView(
                "Select a workflow",
                systemImage: "list.bullet.rectangle"
            )
        }
    }
}
