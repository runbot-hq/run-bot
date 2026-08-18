// MigrationRunnerView.swift
// RunBot

import SwiftUI

/// Placeholder root view for the Local runners destination.
/// Internal layout is introduced in a later migration step.
struct MigrationRunnerView: View {
    /// The placeholder content.
    var body: some View {
        ContentUnavailableView(
            "Local runners",
            systemImage: "desktopcomputer",
            description: Text("Local runner management will be added in a later migration step.")
        )
        .navigationTitle("Local runners")
    }
}
