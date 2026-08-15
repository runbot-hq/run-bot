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
                .frame(minWidth: 180, idealWidth: 220)

            MigrationJobListView()
                .frame(minWidth: 180, idealWidth: 220)

            MigrationStepListView()
                .frame(minWidth: 180, idealWidth: 220)

            MigrationStepLogView()
                .frame(minWidth: 320, idealWidth: 520)
        }
    }
}
