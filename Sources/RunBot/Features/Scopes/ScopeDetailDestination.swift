// ScopeDetailDestination.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - ScopeDetailDestination

/// Thin detail-column destination for the Scopes section. (#2907)
///
/// Passes the live store and selection ID to `ScopeDetailView`.
/// The edit-sheet machinery has been removed; the detail is read-only.
struct ScopeDetailDestination: View {

    // MARK: - Inputs

    /// Live scope store injected at the composition boundary.
    let scopeStore: ScopeStore
    /// Shell-owned selection ID forwarded from `AppDetailView`.
    let selectedScopeID: ScopeEntry.ID?

    // MARK: - Body

    /// Passes store and selection to `ScopeDetailView`.
    var body: some View {
        ScopeDetailView(
            scopeStore: scopeStore,
            selectedScopeID: selectedScopeID
        )
    }
}
