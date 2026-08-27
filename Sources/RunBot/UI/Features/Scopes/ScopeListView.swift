// ScopeListView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - ScopeListView

/// Left pane of the Scopes split view: header, add button, and scope list.
struct ScopeListView: View {

    // MARK: - Inputs

    /// All registered scopes from `ScopeStore`.
    let scopes: [ScopeEntry]
    /// The currently selected scope ID, driven by the parent.
    @Binding var selectedScopeID: ScopeEntry.ID?
    /// Called when the Add scope button is tapped.
    let onAdd: () -> Void
    /// Called when the row toggle is flipped.
    let onSetEnabled: (ScopeEntry, Bool) -> Void
    /// Called when the row delete button is tapped.
    let onDelete: (ScopeEntry) -> Void

    // MARK: - Body

    /// The list pane layout.
    var body: some View {
        ManagementColumn(
            title: "Scopes",
            addTitle: "Add scope",
            onAdd: onAdd
        ) {
            if scopes.isEmpty {
                ColumnPlaceholder(
                    title: "No scopes",
                    systemImage: "scope",
                    description: "Add a repository or organization to monitor."
                )
            } else {
                List(scopes, selection: $selectedScopeID) { scope in
                    ScopeRowView(
                        scope: scope,
                        onSelect: { selectedScopeID = scope.id },
                        onSetEnabled: { onSetEnabled(scope, $0) },
                        onDelete: { onDelete(scope) }
                    )
                    .tag(scope.id)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
            }
        }
    }
}
