// AppShellView.swift
// RunBot

import RunBotCore
import SwiftUI

/// Root two-column navigation shell.
/// Owns the top-level sidebar selection; sidebar routing is wired here.
struct AppShellView: View {
    /// Currently selected sidebar section. Defaults to Workflows.
    @State private var selection: AppSection? = .workflows

    /// Observable runner state — observed here so the `NavigationSplitView`
    /// detail pane re-evaluates when poll data arrives.
    @Environment(RunnerState.self) private var runnerState

    /// Incremented on every poll cycle to force `NavigationSplitView` detail
    /// pane to re-create its child views. `NavigationSplitView` caches the
    /// `detail:` closure result and does not re-evaluate it when the parent
    /// view's `@Environment` changes — only `@State` mutations on the owning
    /// view guarantee a fresh detail tree.
    @State private var refreshID = 0

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
        } detail: {
            AppDetailView(
                selection: selection,
                runnerState: runnerState,
                localRunnerStore: localRunnerStore,
                settingsDependencies: settingsDependencies,
                logFetcher: $logFetcher
            )
            .id(refreshID)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: runnerState.actions) { _, _ in
            refreshID &+= 1
        }
    }
}
