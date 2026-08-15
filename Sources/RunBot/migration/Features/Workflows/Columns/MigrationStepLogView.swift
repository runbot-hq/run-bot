// MigrationStepLogView.swift
// RunBot

import SwiftUI

/// Step-log pane shell. Prompts for a step selection until log rendering is added.
struct MigrationStepLogView: View {
    /// The pane content.
    var body: some View {
        MigrationWorkflowColumn(title: "Step log") {
            MigrationColumnPlaceholder(
                title: "Select a step",
                systemImage: "doc.plaintext"
            )
        }
    }
}
