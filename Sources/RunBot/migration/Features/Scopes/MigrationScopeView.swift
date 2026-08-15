// MigrationScopeView.swift
// RunBot

import SwiftUI

/// Placeholder root view for the Scopes destination.
/// Internal layout is introduced in a later migration step.
struct MigrationScopeView: View {
    /// The placeholder content.
    var body: some View {
        ContentUnavailableView(
            "Scopes",
            systemImage: "scope",
            description: Text("Scope management will be added in a later migration step.")
        )
        .navigationTitle("Scopes")
    }
}
