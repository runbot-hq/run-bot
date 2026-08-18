// MigrationRunnerListView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerListView

/// Left pane: list of configured local runners plus an Add action.
struct MigrationRunnerListView: View {

    // MARK: - Inputs

    /// The current list of configured local runners.
    let runners: [RunnerModel]
    /// The ID of the currently selected runner, driven by the parent.
    @Binding var selectedRunnerID: RunnerModel.ID?
    /// Called when the Add local runner button is tapped.
    let onAdd: () -> Void
    /// Called when a row start/stop toggle changes; receives the runner and new value.
    let onSetRunning: (RunnerModel, Bool) -> Void
    /// Called when a row delete button is tapped; receives the runner to remove.
    let onDelete: (RunnerModel) -> Void

    // MARK: - Body

    /// The column layout: header with Add action, divider, list or empty placeholder.
    var body: some View {
        MigrationWorkflowColumn(title: "Local runners") {
            VStack(spacing: 0) {
                HStack {
                    Button(action: onAdd) {
                        Label("Add local runner", systemImage: "plus")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(12)

                Divider()

                if runners.isEmpty {
                    MigrationColumnPlaceholder(
                        title: "No local runners",
                        systemImage: "desktopcomputer",
                        description: "Add a local self-hosted runner to manage it."
                    )
                } else {
                    List(runners, selection: $selectedRunnerID) { runner in
                        LocalRunnerRowView(
                            runner: runner,
                            onSelect: { selectedRunnerID = runner.id },
                            onSetRunning: { onSetRunning(runner, $0) },
                            onDelete: { onDelete(runner) }
                        )
                        .tag(runner.id)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }
}
