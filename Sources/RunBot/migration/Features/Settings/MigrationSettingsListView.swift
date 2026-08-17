// MigrationSettingsListView.swift
// RunBot

import SwiftUI

// MARK: - MigrationSettingsListView

/// Settings section list shown in the content column of the app shell.
///
/// Deliberately omits a header row: the sidebar already identifies the
/// Settings destination. Selection is owned by `AppShellView` and flows
/// down as a binding.
///
/// ## Row styling
/// Rows use 15-point medium-weight text, 46-point height, and 12-point
/// horizontal inset so they feel proportionate at the 240–280-point column
/// width owned by `AppContentView`.
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
                .font(.system(size: 15, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 46)
                .tag(section)
        }
        .listStyle(.sidebar)
    }
}
