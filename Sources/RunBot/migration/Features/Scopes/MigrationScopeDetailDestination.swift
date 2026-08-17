// MigrationScopeDetailDestination.swift
// RunBot

import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - MigrationScopeDetailDestination

/// Detail-column destination for the Scopes section.
///
/// Wraps `MigrationScopeDetailView` and owns the edit-sheet lifecycle
/// so the detail view remains purely presentational. (#2900)
@MainActor
struct MigrationScopeDetailDestination: View {

    // MARK: - Inputs

    /// The resolved scope entry for the current selection, or `nil`.
    let scope: ScopeEntry?

    // MARK: - Environment

    // swiftlint:disable:next missing_docs
    @Environment(MBKOverlayGate.self) private var overlayGate

    // MARK: - Local UI state

    /// Non-nil while `ScopeEditSheet` is being prepared or presented.
    @State private var scopeEditPresentation: ScopeEditPresentation?
    /// Guards against duplicate edit taps during async fetch.
    @State private var isPreparingEdit = false

    // MARK: - Body

    /// Detail view with edit-sheet wiring.
    var body: some View {
        MigrationScopeDetailView(
            scope: scope,
            onEdit: prepareEdit
        )
        .sheet(item: $scopeEditPresentation) { presentation in
            ScopeEditSheet(
                scopeEntry: presentation.entry,
                preferences: presentation.preferences,
                isPresented: Binding(
                    get: { scopeEditPresentation != nil },
                    set: { if !$0 { scopeEditPresentation = nil } }
                )
            )
            .environment(overlayGate)
        }
    }

    // MARK: - Actions

    /// Fetches preferences asynchronously then presents the edit sheet.
    private func prepareEdit(_ entry: ScopeEntry) {
        guard !isPreparingEdit, scopeEditPresentation == nil else { return }
        isPreparingEdit = true
        Task {
            let prefs = await ScopePreferencesStore.shared.preferences(for: entry.scope)
            scopeEditPresentation = ScopeEditPresentation(entry: entry, preferences: prefs)
            isPreparingEdit = false
        }
    }
}
