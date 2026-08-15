// MigrationWorkflowView.swift
// RunBot

import SwiftUI

/// Root view for the Workflows destination.
///
/// Owns the four-pane `HSplitView` and the in-memory selection chain.
/// Production callers pass `workflows: []` until the store is wired in step 5+.
struct MigrationWorkflowView: View {

    /// Workflow data provided by the caller. Empty until production data is wired.
    let workflows: [WorkflowActionGroup]

    /// In-memory selection state for the three-level hierarchy.
    @State private var selection = MigrationWorkflowSelection()

    // MARK: - Derived selection

    /// The workflow matching the current `selection.workflowID`, or `nil`.
    private var selectedWorkflow: WorkflowActionGroup? {
        workflows.first { $0.id == selection.workflowID }
    }

    /// The job matching the current `selection.jobID` within the selected workflow, or `nil`.
    private var selectedJob: ActiveJob? {
        selectedWorkflow?.jobs.first { $0.id == selection.jobID }
    }

    /// The step matching the current `selection.stepNumber` within the selected job, or `nil`.
    private var selectedStep: GitHubStep? {
        selectedJob?.steps.first { $0.number == selection.stepNumber }
    }

    // MARK: - Body

    /// The four-pane horizontal split layout.
    var body: some View {
        HSplitView {
            MigrationWorkflowListView(
                workflows: workflows,
                selection: selection
            )
            .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationJobListView(
                jobs: selectedWorkflow?.jobs ?? [],
                selection: selection
            )
            .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationStepListView(
                steps: selectedJob?.steps ?? [],
                selection: selection
            )
            .frame(minWidth: 150, idealWidth: 190, maxWidth: 320)

            MigrationStepLogView(selectedStep: selectedStep)
            .frame(minWidth: 260, idealWidth: 380, maxWidth: 800)
        }
    }
}
