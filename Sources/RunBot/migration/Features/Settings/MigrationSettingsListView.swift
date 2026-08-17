// MigrationSettingsListView.swift
// RunBot

import SwiftUI

// MARK: - MigrationSettingsListView

/// Settings section list shown in the content column of the app shell.
///
/// Deliberately omits a header row: the sidebar already identifies the
/// Settings destination. Selection is owned by `AppShellView` and flows
/// down as a binding.
@MainActor
struct MigrationSettingsListView: View {

    // MARK: - Binding

    /// The currently selected settings section.
    @Binding var selection: MigrationSettingsSection?

    // MARK: - Body

    /// The settings section list.
    var body: some View {
        List(MigrationSettingsSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .listStyle(.sidebar)
    }
}
