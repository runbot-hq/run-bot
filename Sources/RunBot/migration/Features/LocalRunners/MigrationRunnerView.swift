// MigrationRunnerView.swift
// RunBot
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerView

/// Root two-pane local runner management view.
///
/// Receives an already-configured `LocalRunnerStore` from the composition root.
/// The store must be configured before this view is mounted.
@MainActor
struct MigrationRunnerView: View {

    // MARK: - Inputs

    let runnerState: RunnerState
    let localRunnerStore: LocalRunnerStore

    // MARK: - Local UI state

    @State private var selectedRunnerID: RunnerModel.ID?
    @State private var isAddRunnerPresented = false

    // MARK: - Computed

    private var selectedRunner: RunnerModel? {
        runnerState.localRunners.first { $0.id == selectedRunnerID }
    }

    // MARK: - Body

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
        .mbkSheet(isPresented: $isAddRunnerPresented) {
            AddRunnerSheet(
                isPresented: $isAddRunnerPresented,
                onComplete: {
                    Task { await localRunnerStore.refreshAsync() }
                }
            )
        }
        .onChange(of: runnerState.localRunners) { _, runners in
            if let id = selectedRunnerID, !runners.contains(where: { $0.id == id }) {
                selectedRunnerID = nil
            }
        }
        .task { await localRunnerStore.refreshAsync() }
    }

    // MARK: - Actions

    private func setRunning(_ runner: RunnerModel, isRunning: Bool) {
        Task {
            await localRunnerStore.optimisticallySetRunning(runner.runnerName, isRunning: isRunning)
            await localRunnerStore.refreshAsync()
        }
    }

    private func delete(_ runner: RunnerModel) {
        let wasSelected = runner.id == selectedRunnerID
        if wasSelected { selectedRunnerID = nil }
        Task {
            await localRunnerStore.optimisticallyRemove(runner.runnerName)
        }
    }
}
