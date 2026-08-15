// MigrationRunnerDetailView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerDetailView

/// Right pane: displays information and configuration for the selected runner,
/// or a placeholder when nothing is selected.
struct MigrationRunnerDetailView: View {

    // MARK: - Inputs

    let runner: RunnerModel?

    // MARK: - Body

    var body: some View {
        if let runner {
            RunnerDetailContentView(runner: runner)
        } else {
            MigrationColumnPlaceholder(
                title: "Select a local runner",
                systemImage: "desktopcomputer"
            )
        }
    }
}
