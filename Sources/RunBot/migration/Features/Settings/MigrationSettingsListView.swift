// MigrationSettingsListView.swift
// RunBot

import SwiftUI

// MARK: - MigrationSettingsListView

/// Left-hand list pane for the two-pane settings layout.
///
/// Mirrors the header style of `MigrationManagementColumn` but omits the Add
/// button because settings sections are static.
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

    /// The settings list column.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            List(MigrationSettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
