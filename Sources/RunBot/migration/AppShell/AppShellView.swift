// AppShellView.swift
// RunBot

import RunBotCore
import SwiftUI

/// Root three-column navigation shell: sidebar, content, and detail.
///
/// Owns the top-level sidebar selection and the shared workflow selection so
/// the content column (workflow hierarchy) and detail column (step log) stay
/// in sync (issue #2880).
struct AppShellView: View {
    /// Currently selected sidebar section. Defaults to Workflows.
    @State private var selection: AppSection? = .workflows

    /// Shared workflow → job → step selection. Owned at the shell level
    /// because the hierarchy and step-log columns both read and mutate it.
    @State private var workflowSelection = MigrationWorkflowSelection()

    /// Runner store forwarded from the composition root.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: MigrationSettingsDependencies
    /// Shared log fetcher — owned by `MigrationAppDependencies`, threaded down
    /// via `@Binding` so the ZIP cache survives column navigations.
    @Binding var logFetcher: LogFetcher

    /// The top-level split-view layout.
    var body: some View {
        NavigationSplitView {
            AppSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 210,
                    max: 260
                )
        } content: {
            AppContentView(
                selection: selection,
                runnerState: runnerState,
                localRunnerStore: localRunnerStore,
                settingsDependencies: settingsDependencies,
                workflowSelection: workflowSelection
            )
        } detail: {
            AppDetailView(
                selection: selection,
                runnerState: runnerState,
                workflowSelection: workflowSelection,
                logFetcher: $logFetcher
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }
}
