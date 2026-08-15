// AppShellView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

/// Root two-column navigation shell.
/// Owns the top-level sidebar selection; sidebar routing is wired here.
struct AppShellView: View {
    /// Currently selected sidebar section. Defaults to Workflows.
    @State private var selection: AppSection? = .workflows

    /// Authentication injected from `RunBotDesktopApp`.
    @Environment(GitHubAuthentication.self) private var authentication: GitHubAuthentication

    /// Runner store forwarded from the composition root.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: MigrationSettingsDependencies

    /// The top-level split-view layout.
    var body: some View {
        NavigationSplitView {
            AppSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 210,
                    max: 260
                )
        } detail: {
            AppDetailView(
                selection: selection,
                authentication: authentication,
                runnerState: runnerState,
                localRunnerStore: localRunnerStore,
                settingsDependencies: settingsDependencies
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }
}
