// MigrationScopeDetailDestination.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationScopeDetailDestination

/// Thin detail-column destination for the Scopes section. (#2907)
///
/// Passes the live store and selection ID to `MigrationScopeDetailView`.
/// The edit-sheet machinery has been removed; the detail is read-only.
struct MigrationScopeDetailDestination: View {

    // MARK: - Inputs

    let scopeStore: ScopeStore
    let selectedScopeID: ScopeEntry.ID?

    // MARK: - Body

    var body: some View {
        MigrationScopeDetailView(
            scopeStore: scopeStore,
            selectedScopeID: selectedScopeID
        )
    }
}
