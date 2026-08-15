// MigrationSettingsView.swift
// RunBot

import SwiftUI

/// Placeholder root view for the Settings destination.
/// Internal layout is introduced in a later migration step.
struct MigrationSettingsView: View {
    /// The placeholder content.
    var body: some View {
        ContentUnavailableView(
            "Settings",
            systemImage: "gearshape",
            description: Text("Settings controls will be added in a later migration step.")
        )
        .navigationTitle("Settings")
    }
}
