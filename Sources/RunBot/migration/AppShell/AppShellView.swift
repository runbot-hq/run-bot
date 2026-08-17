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

    /// Shared settings section selection. Owned at the shell level so the
    /// content column (list) and detail column (section view) stay in sync.
    @State private var settingsSelection: MigrationSettingsSection? = .authentication

    /// Shared runner selection. Owned here so the content list and detail column
    /// resolve the same model. (#2900)
    @State private var selectedRunnerID: RunnerModel.ID?

    /// Shared scope selection. Owned here so the content list and detail column
    /// resolve the same model. (#2900)
    @State private var selectedScopeID: ScopeEntry.ID?

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
                workflowSelection: workflowSelection,
                settingsSelection: $settingsSelection,
                selectedRunnerID: $selectedRunnerID,
                selectedScopeID: $selectedScopeID
            )
        } detail: {
            AppDetailView(
                selection: selection,
                runnerState: runnerState,
                workflowSelection: workflowSelection,
                settingsSelection: settingsSelection,
                settingsDependencies: settingsDependencies,
                selectedRunnerID: selectedRunnerID,
                selectedScopeID: selectedScopeID,
                logFetcher: $logFetcher
            )
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }
}
