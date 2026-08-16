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

    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: MigrationSettingsDependencies
    /// Shared log fetcher — threaded from `AppShellView`.
    @Binding var logFetcher: LogFetcher

    /// Routes to the corresponding feature-root view.
    var body: some View {
        switch selection {
        case .workflows:
            MigrationWorkflowView(logFetcher: $logFetcher)
        case .localRunners:
            MigrationRunnerView(
                localRunnerStore: localRunnerStore
            )
        case .scopes:
            MigrationScopeView(scopeStore: .shared)
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
