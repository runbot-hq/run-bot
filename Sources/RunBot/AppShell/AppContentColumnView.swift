// AppContentColumnView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Content-column router. Switches on the current sidebar selection.
///
/// Workflows shows the workflow hierarchy (issue #2880); the other destinations
/// host their existing self-contained feature roots. The `nil` case is
/// defensive; Workflows is always selected on launch.
struct AppContentColumnView: View {
    /// The currently selected sidebar destination.
    let selection: AppDestination?

    /// Observable runner state pushed by `LocalRunnerStore`.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Shared workflow → job → step selection owned by `AppNavigationSplitView`.
    var workflowSelection: WorkflowSelection

    /// Shared settings section selection owned by `AppNavigationSplitView`.
    @Binding var settingsSelection: SettingsSection?
    /// Shared runner selection owned by `AppNavigationSplitView`. (#2900)
    @Binding var selectedRunnerID: RunnerModel.ID?
    /// Shared scope selection owned by `AppNavigationSplitView`. (#2900)
    @Binding var selectedScopeID: ScopeEntry.ID?

    /// Routes to the corresponding content-column view.
    var body: some View {
        switch selection {
        case .workflows:
            WorkflowHierarchyView(
                runnerState: runnerState,
                selection: workflowSelection
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 640)
        case .localRunners:
            RunnerListDestination(
                runnerState: runnerState,
                localRunnerStore: localRunnerStore,
                selectedRunnerID: $selectedRunnerID
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 520)
        case .scopes:
            ScopeListDestination(
                scopeStore: .shared,
                selectedScopeID: $selectedScopeID
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 520)
        case .settings:
            SettingsListView(selection: $settingsSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        case nil:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left"
            )
        }
    }
}
