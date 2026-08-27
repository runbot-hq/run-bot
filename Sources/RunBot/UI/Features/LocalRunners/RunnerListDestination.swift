// RunnerListDestination.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - RunnerListDestination

/// Content-column destination for the Local Runners section.
///
/// Owns sheet presentation and action dispatch while keeping
/// `RunnerListView` purely presentational. Selection is
/// owned by `AppNavigationSplitView` and passed in as a binding so the detail
/// column can resolve the selected runner independently. (#2900)
@MainActor
struct RunnerListDestination: View {

    // MARK: - Inputs

    /// Observable runner state pushed by `LocalRunnerStore`.
    let runnerState: RunnerState
    /// The configured local-runner store.
    let localRunnerStore: LocalRunnerStore
    /// Shell-owned selection binding shared with `AppDetailColumnView`.
    @Binding var selectedRunnerID: RunnerModel.ID?

    // MARK: - Environment

    // swiftlint:disable:next missing_docs
    @Environment(GitHubAuthentication.self) private var authentication

    // MARK: - Local UI state

    /// Controls presentation of `AddRunnerSheet`.
    @State private var isAddRunnerPresented = false

    // MARK: - Body

    /// List view with sheet and action wiring.
    var body: some View {
        RunnerListView(
            runners: runnerState.localRunners,
            selectedRunnerID: $selectedRunnerID,
            onAdd: { isAddRunnerPresented = true },
            onSetRunning: setRunning,
            onDelete: delete
        )
        .sheet(isPresented: $isAddRunnerPresented) {
            AddRunnerSheet(
                isPresented: $isAddRunnerPresented,
                onComplete: {
                    Task { await localRunnerStore.refreshAsync() }
                },
                localRunners: runnerState.localRunners
            )
            .environment(authentication)
        }
        .onChange(of: runnerState.localRunners) { _, runners in
            if let id = selectedRunnerID, !runners.contains(where: { $0.id == id }) {
                selectedRunnerID = nil
            }
        }
        .task { await localRunnerStore.refreshAsync() }
    }

    // MARK: - Actions

    /// Optimistically flips running state then refreshes.
    private func setRunning(_ runner: RunnerModel, isRunning: Bool) {
        Task {
            await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: isRunning)
            await localRunnerStore.refreshAsync()
        }
    }

    /// Clears selection immediately, then optimistically removes the runner.
    private func delete(_ runner: RunnerModel) {
        let wasSelected = runner.id == selectedRunnerID
        if wasSelected { selectedRunnerID = nil }
        Task {
            await localRunnerStore.optimisticallyRemove(runner.runnerName)
        }
    }
}
