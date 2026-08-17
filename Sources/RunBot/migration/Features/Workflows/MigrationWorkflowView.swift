// MigrationWorkflowView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Root view for the Workflows destination.
///
/// Owns the four-pane `HSplitView` and the in-memory selection chain.
/// Receives `RunnerState` as a `@Bindable` parameter threaded from
/// `AppShellView` (which carries `@Environment(RunnerState.self)`).
/// AppShellView's `body` re-evaluates on poll data changes, producing
/// a new `AppDetailView` → new `MigrationWorkflowView` with the latest snapshot.
@MainActor
struct MigrationWorkflowView: View {

    /// Observable runner state threaded from `AppShellView`.
    @Bindable var runnerState: RunnerState
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
