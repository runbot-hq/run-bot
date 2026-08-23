// SettingsListView.swift
// RunBot

import SwiftUI

// MARK: - SettingsListView

/// Settings section list shown in the content column of the app shell.
///
/// Shows a compact "Settings" title above the section list, then the
/// section rows. Selection is owned by `AppShellView` and flows down
/// as a binding. (#2898)
///
/// ## Row styling
/// Rows use 15-point medium-weight text, a 32-point label height, and
/// 3-point vertical list insets, producing a native selected-row height
/// around 40–44 points. The native sidebar selection background is used
/// directly — no manual selection overlay is drawn.
@MainActor
struct SettingsListView: View {

    // MARK: - Binding

    /// The currently selected settings section.
    @Binding var selection: SettingsSection?

    // MARK: - Body

    /// The settings section list, prefixed by a compact page title.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 14)

            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .imageScale(.medium)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 32)
                    .tag(section)
                    .listRowInsets(
                        EdgeInsets(
                            top: 3,
                            leading: 12,
                            bottom: 3,
                            trailing: 12
                        )
                    )
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }
}
