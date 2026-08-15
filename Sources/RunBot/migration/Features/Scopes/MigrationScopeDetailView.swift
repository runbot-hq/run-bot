// MigrationScopeDetailView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationScopeDetailView

/// Right pane of the Scopes split view: displays information for the selected scope.
struct MigrationScopeDetailView: View {

    // MARK: - Inputs

    /// The currently selected scope, or `nil` when nothing is selected.
    let scope: ScopeEntry?
    /// Called when the Edit scope button is tapped.
    let onEdit: (ScopeEntry) -> Void

    // MARK: - Body

    /// The detail pane layout.
    var body: some View {
        if let scope {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(scope.displayName ?? scope.scope)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)

                    LabeledContent("Scope", value: scope.scope)
                    LabeledContent(
                        "Type",
                        value: scope.scope.contains("/") ? "Repository" : "Organization"
                    )
                    LabeledContent(
                        "Status",
                        value: scope.isEnabled ? "Enabled" : "Disabled"
                    )

                    Button("Edit scope") {
                        onEdit(scope)
                    }
                }
                .padding(20)
                .frame(maxWidth: 640, alignment: .leading)
            }
        } else {
            MigrationColumnPlaceholder(
                title: "Select a scope",
                systemImage: "scope"
            )
        }
    }
}
