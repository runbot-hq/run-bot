// MigrationWorkflowView.swift
// RunBot

import SwiftUI

/// Root view for the Workflows destination.
/// Owns the four-pane `HSplitView` workflow layout.
/// Rows and feature data are introduced in a later migration step.
struct MigrationWorkflowView: View {
    /// The four-pane horizontal split layout.
    var body: some View {
        HSplitView {
            MigrationWorkflowListView()
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationJobListView()
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationStepListView()
                .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationStepLogView()
                .frame(minWidth: 260, idealWidth: 380, maxWidth: 800)
        }
    }
}
