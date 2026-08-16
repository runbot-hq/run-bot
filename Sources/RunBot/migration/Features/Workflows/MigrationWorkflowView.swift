// MigrationWorkflowView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Root view for the Workflows destination.
///
/// Owns the four-pane `HSplitView` and the in-memory selection chain.
/// Observes `RunnerState` directly via `@Environment` so each poll
/// snapshot updates all three hierarchy columns in place without a
/// selection reset.
@MainActor
struct MigrationWorkflowView: View {

    /// Observable runner state injected via `.environment()` at the
    /// composition root. `@Environment` tracks property accesses for
    /// SwiftUI observation, so every poll snapshot triggers a re-render.
    @Environment(RunnerState.self) private var runnerState
    /// Shared log fetcher threaded from the composition root.
    @Binding var logFetcher: LogFetcher

    /// In-memory selection state for the three-level hierarchy.
    @State private var selection = MigrationWorkflowSelection()

    // MARK: - Derived data

    /// Current workflow snapshot derived from the observable runner state.
    private var workflows: [WorkflowActionGroup] { runnerState.actions }

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

            MigrationStepLogView(
                selectedJob: selectedJob,
                selectedStep: selectedStep,
                logFetcher: $logFetcher
            )
            .frame(minWidth: 260, idealWidth: 380, maxWidth: 800)
        }
        .onChange(of: runnerState.actions) { _, actions in
            selection.reconcile(workflows: actions)
        }
    }
}
