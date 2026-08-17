// AppContentView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Content-column router. Switches on the current sidebar selection.
///
/// Workflows shows the workflow hierarchy (issue #2880); the other sections
/// host their existing self-contained feature roots. The `nil` case is
/// defensive; Workflows is always selected on launch.
struct AppContentView: View {
    /// The currently selected sidebar section.
    let selection: AppSection?

    /// Observable runner state pushed by `LocalRunnerStore`.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: MigrationSettingsDependencies
    /// Shared workflow → job → step selection owned by `AppShellView`.
    var workflowSelection: MigrationWorkflowSelection

    /// Routes to the corresponding content-column view.
    var body: some View {
        switch selection {
        case .workflows:
            MigrationWorkflowHierarchyView(
                runnerState: runnerState,
                selection: workflowSelection
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 640)
        case .localRunners:
            MigrationRunnerView(
                runnerState: runnerState,
                localRunnerStore: localRunnerStore
            )
            .navigationSplitViewColumnWidth(min: 600, ideal: 760)
        case .scopes:
            MigrationScopeView(scopeStore: .shared)
                .navigationSplitViewColumnWidth(min: 600, ideal: 760)
        case .settings:
            MigrationSettingsView(dependencies: settingsDependencies)
                .navigationSplitViewColumnWidth(min: 600, ideal: 760)
        case nil:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left"
            )
        }
    }
}
