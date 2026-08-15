// AppDetailView.swift
// RunBot

import SwiftUI

/// Detail column router. Switches on the current sidebar selection.
/// The `nil` case is defensive; Workflows is always selected on launch.
struct AppDetailView: View {
    /// The currently selected sidebar section.
    let selection: AppSection?

    /// Routes to the corresponding feature-root view.
    var body: some View {
        switch selection {
        case .workflows:
            MigrationWorkflowView()
        case .localRunners:
            MigrationRunnerView()
        case .scopes:
            MigrationScopeView()
        case .settings:
            MigrationSettingsView()
        case nil:
            ContentUnavailableView(
                "Select an item",
                systemImage: "sidebar.left"
            )
        }
    }
}
