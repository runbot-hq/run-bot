// MigrationWorkflowView.swift
// RunBot

import SwiftUI

/// Placeholder root view for the Workflows destination.
/// Internal layout is introduced in a later migration step.
struct MigrationWorkflowView: View {
    /// The placeholder content.
    var body: some View {
        ContentUnavailableView(
            "Workflows",
            systemImage: "bolt.horizontal.circle",
            description: Text("Workflow navigation will be added in the next migration step.")
        )
        .navigationTitle("Workflows")
    }
}
