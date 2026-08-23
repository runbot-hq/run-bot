// AppDetailView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Detail-column router. Shows the step log for the Workflows section and a
/// neutral placeholder for sections whose content column is self-contained.
///
/// Selected job and step are derived here from the shared selection plus the
/// live runner snapshot so the log always reflects current data.
struct AppDetailView: View {
    /// The currently selected sidebar section.
    let selection: AppSection?

    /// Observable runner state pushed by `LocalRunnerStore`.
    let runnerState: RunnerState
    /// Shared workflow → job → step selection owned by `AppShellView`.
    var workflowSelection: WorkflowSelection
    /// Selected settings section forwarded from `AppShellView`.
    let settingsSelection: SettingsSection?

    /// Settings services forwarded from the composition root.
    let settingsDependencies: SettingsDependencies

    /// Shell-owned runner selection forwarded from `AppShellView`. (#2900)
    let selectedRunnerID: RunnerModel.ID?
    /// Shell-owned scope selection forwarded from `AppShellView`. (#2900)
    let selectedScopeID: ScopeEntry.ID?

    /// Shared log fetcher — threaded from `AppShellView`.
    @Binding var logFetcher: LogFetcher

    // MARK: - Derived selection

    /// The workflow matching the current selection, or `nil`.
    private var selectedWorkflow: WorkflowActionGroup? {
        runnerState.actions.first { $0.id == workflowSelection.workflowID }
    }

    /// The job matching the current selection within the selected workflow, or `nil`.
    private var selectedJob: ActiveJob? {
        selectedWorkflow?.jobs.first { $0.id == workflowSelection.jobID }
    }

    /// The step matching the current selection within the selected job, or `nil`.
    private var selectedStep: GitHubStep? {
        selectedJob?.steps.first { $0.number == workflowSelection.stepNumber }
    }

    // MARK: - Body

    /// Routes to the corresponding detail-column view.
    var body: some View {
        switch selection {
        case .workflows:
            StepLogPaneView(
                selectedJob: selectedJob,
                selectedStep: selectedStep,
                logFetcher: $logFetcher
            )
        case .settings:
            SettingsDetailView(
                selection: settingsSelection,
                dependencies: settingsDependencies
            )
        case .localRunners:
            RunnerDetailView(
                runner: runnerState.localRunners.first { $0.id == selectedRunnerID }
            )
        case .scopes:
            ScopeDetailDestination(
                scopeStore: ScopeStore.shared,
                selectedScopeID: selectedScopeID
            )
        case nil:
            ContentUnavailableView(
                "No details",
                systemImage: "sidebar.right"
            )
        }
    }
}
