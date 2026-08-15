// MigrationRunnerDetailView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - MigrationRunnerDetailView

/// Right pane: displays information and configuration for the selected runner,
/// or a placeholder when nothing is selected.
struct MigrationRunnerDetailView: View {

    // MARK: - Inputs

    /// The runner whose detail should be displayed, or `nil` when nothing is selected.
    let runner: RunnerModel?

    // MARK: - Body

    /// Shows `RunnerDetailContentView` when a runner is selected, otherwise a placeholder.
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
