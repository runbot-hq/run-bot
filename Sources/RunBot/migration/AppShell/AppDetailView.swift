// AppDetailView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Detail column router. Switches on the current sidebar selection.
/// The `nil` case is defensive; Workflows is always selected on launch.
struct AppDetailView: View {
    /// The currently selected sidebar section.
    let selection: AppSection?

    /// Injected from `AppShellView`; forwarded to scope management.
    let authentication: GitHubAuthentication

    /// Observable runner state pushed by `LocalRunnerStore`.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: MigrationSettingsDependencies

    /// Routes to the corresponding feature-root view.
    var body: some View {
        switch selection {
        case .workflows:
            MigrationWorkflowView(workflows: runnerState.actions)
        case .localRunners:
            MigrationRunnerView(
                runnerState: runnerState,
                localRunnerStore: localRunnerStore
            )
        case .scopes:
            MigrationScopeView(scopeStore: .shared, authentication: authentication)
        case .settings:
            MigrationSettingsView(dependencies: settingsDependencies)
        case nil:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left"
            )
        }
    }
}
