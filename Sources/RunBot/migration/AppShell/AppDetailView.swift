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

    /// Runner store forwarded from the composition root.
    let runnerState: RunnerState
    let localRunnerStore: LocalRunnerStore

    /// Routes to the corresponding feature-root view.
    var body: some View {
        switch selection {
        case .workflows:
            MigrationWorkflowView(workflows: [])
        case .localRunners:
            MigrationRunnerView(
                runnerState: runnerState,
                localRunnerStore: localRunnerStore
            )
        case .scopes:
            MigrationScopeView(scopeStore: .shared, authentication: authentication)
        case .settings:
            MigrationSettingsView()
        case nil:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left"
            )
        }
    }
}
