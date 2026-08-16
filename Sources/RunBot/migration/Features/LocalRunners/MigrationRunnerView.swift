// MigrationRunnerView.swift
// RunBot
import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerView

/// Root two-pane local runner management view.
///
/// Receives an already-configured `LocalRunnerStore` from the composition root.
/// The store must be configured before this view is mounted.
/// `RunnerState` is injected via `.environment()` so local-runner list
/// mutations trigger reactive re-renders.
@MainActor
struct MigrationRunnerView: View {

    // MARK: - Inputs

    /// The configured local-runner store; must be configured before this view mounts.
    let localRunnerStore: LocalRunnerStore

    /// Observable runner state injected via `.environment()` at the
    /// composition root. Accessed via `@Environment` so the view
    /// re-renders when `localRunners` changes.
    @Environment(RunnerState.self) private var runnerState

    // swiftlint:disable:next missing_docs
    @Environment(GitHubAuthentication.self) private var authentication
    // swiftlint:disable:next missing_docs
    @Environment(MBKOverlayGate.self) private var overlayGate

    // MARK: - Local UI state

    /// The ID of the runner whose detail is displayed in the right pane.
    @State private var selectedRunnerID: RunnerModel.ID?
    /// Controls presentation of `AddRunnerSheet`.
    @State private var isAddRunnerPresented = false

    // MARK: - Computed

    /// The `RunnerModel` matching `selectedRunnerID`, or `nil` when nothing is selected.
    private var selectedRunner: RunnerModel? {
        runnerState.localRunners.first { $0.id == selectedRunnerID }
    }

    // MARK: - Body

    /// Root `HSplitView` with list pane left and detail pane right.
    var body: some View {
        HSplitView {
            MigrationRunnerListView(
                runners: runnerState.localRunners,
                selectedRunnerID: $selectedRunnerID,
                onAdd: { isAddRunnerPresented = true },
                onSetRunning: setRunning,
                onDelete: delete
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

            MigrationRunnerDetailView(runner: selectedRunner)
                .frame(minWidth: 360, idealWidth: 520, maxWidth: 900)
        }
        .sheet(isPresented: $isAddRunnerPresented) {
            AddRunnerSheet(
                isPresented: $isAddRunnerPresented,
                onComplete: {
                    Task { await localRunnerStore.refreshAsync() }
                },
                localRunners: runnerState.localRunners
            )
            .environment(authentication)
            .environment(overlayGate)
        }
        .onChange(of: runnerState.localRunners) { _, runners in
            if let id = selectedRunnerID, !runners.contains(where: { $0.id == id }) {
                selectedRunnerID = nil
            }
        }
        .task { await localRunnerStore.refreshAsync() }
    }

    // MARK: - Actions

    /// Optimistically flips the runner service state then refreshes.
    private func setRunning(_ runner: RunnerModel, isRunning: Bool) {
        Task {
            await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: isRunning)
            await localRunnerStore.refreshAsync()
        }
    }

    /// Clears selection immediately then optimistically removes the runner from the store.
    private func delete(_ runner: RunnerModel) {
        let wasSelected = runner.id == selectedRunnerID
        if wasSelected { selectedRunnerID = nil }
        Task {
            await localRunnerStore.optimisticallyRemove(runner.runnerName)
        }
    }
}
