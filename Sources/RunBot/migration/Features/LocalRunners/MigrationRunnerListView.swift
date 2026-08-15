// MigrationRunnerListView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerListView

/// Left pane: list of configured local runners plus an Add action.
struct MigrationRunnerListView: View {

    // MARK: - Inputs

    let runners: [RunnerModel]
    @Binding var selectedRunnerID: RunnerModel.ID?
    let onAdd: () -> Void
    let onSetRunning: (RunnerModel, Bool) -> Void
    let onDelete: (RunnerModel) -> Void

    // MARK: - Body

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
