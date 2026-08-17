// MigrationSettingsListView.swift
// RunBot

import SwiftUI

// MARK: - MigrationSettingsListView

/// Left-hand list pane for the two-pane settings layout.
///
/// Mirrors `MigrationScopeListView` and `MigrationRunnerListView`:
/// wraps a `List` keyed on `MigrationSettingsSection` inside a
/// `MigrationWorkflowColumn`. There is no add button because settings
/// sections are static.
///
/// ## Selection
/// Selection is owned by the parent `MigrationSettingsView` so that
/// the detail pane can react to it without prop-drilling through this view.
@MainActor
struct MigrationSettingsListView: View {

    // MARK: - Binding

    /// The currently selected settings section.
    @Binding var selection: MigrationSettingsSection?

    // MARK: - Body

    var body: some View {
        MigrationWorkflowColumn(title: "Settings") {
            List(MigrationSettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
        }
    }
}
