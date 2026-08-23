// MigrationScopeListDestination.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationScopeListDestination

/// Content-column destination for the Scopes section.
///
/// Owns sheet presentation and action dispatch while keeping
/// `MigrationScopeListView` purely presentational. Selection is
/// owned by `AppShellView` and passed in as a binding so the detail
/// column can resolve the selected scope independently. (#2900)
@MainActor
struct MigrationScopeListDestination: View {

    // MARK: - Inputs

    /// The shared scope store, injected at the composition boundary.
    let scopeStore: ScopeStore
    /// Shell-owned selection binding shared with `AppDetailView`.
    @Binding var selectedScopeID: ScopeEntry.ID?

    // MARK: - Local UI state

    /// Controls presentation of `AddScopeSheet`.
    @State private var isAddScopePresented = false

    // MARK: - Body

    /// List view with sheet and action wiring.
    var body: some View {
        MigrationScopeListView(
            scopes: scopeStore.entries,
            selectedScopeID: $selectedScopeID,
            onAdd: { isAddScopePresented = true },
            onSetEnabled: setEnabled,
            onDelete: delete
        )
        .sheet(isPresented: $isAddScopePresented) {
            AddScopeSheet(isPresented: $isAddScopePresented)
        }
        .onChange(of: scopeStore.entries) { _, newEntries in
            if let id = selectedScopeID,
               !newEntries.contains(where: { $0.id == id }) {
                selectedScopeID = nil
            }
        }
    }

    // MARK: - Actions

    /// Flips the enabled state via the store.
    private func setEnabled(_ entry: ScopeEntry, _ enabled: Bool) {
        scopeStore.setEnabled(entry.id, enabled)
    }

    /// Cleans up preferences then removes the scope; clears selection if needed.
    private func delete(_ entry: ScopeEntry) {
        if selectedScopeID == entry.id { selectedScopeID = nil }
        Task {
            await ScopePreferencesStore.shared.cleanUp(scope: entry.scope)
            scopeStore.remove(id: entry.id)
        }
    }
}
