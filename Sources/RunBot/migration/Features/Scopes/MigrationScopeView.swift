// MigrationScopeView.swift
// RunBot

import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - MigrationScopeView

/// Root view for the Scopes destination in the migration app shell.
///
/// Owns all scope-specific state and sheet presentation. The `scopeStore`
/// is resolved once at the composition boundary in `AppDetailView` so child
/// views do not each pull from `.shared`.
///
/// No `onRestartPolling` callback is needed — `ScopeStore` mutations are
/// observed by `RunnerStore`'s `withObservationTracking` loop automatically.
@MainActor
struct MigrationScopeView: View {

    // MARK: - Inputs

    /// The shared scope store, injected at the composition boundary.
    let scopeStore: ScopeStore

    /// Authentication forwarded from the app shell for `AddScopeSheet`.
    let authentication: GitHubAuthentication

    // MARK: - Environment

    /// Overlay gate injected from the window root; forwarded to sheet boundaries.
    @Environment(MBKOverlayGate.self) private var overlayGate

    // MARK: - Local UI state

    /// The ID of the currently selected scope in the list pane.
    @State private var selectedScopeID: ScopeEntry.ID?
    /// Controls presentation of `AddScopeSheet`.
    @State private var isAddScopePresented = false
    /// Non-nil while `ScopeEditSheet` is being prepared or presented.
    @State private var scopeEditPresentation: ScopeEditPresentation?
    /// `true` from the moment `prepareEdit` is called until the preferences fetch
    /// completes and `scopeEditPresentation` is set. Blocks duplicate Edit taps
    /// that arrive before the async fetch returns (at which point
    /// `scopeEditPresentation` is still `nil` and the old guard would pass).
    @State private var isPreparingEdit = false

    // MARK: - Computed

    /// The full `ScopeEntry` for the current `selectedScopeID`, if any.
    private var selectedScope: ScopeEntry? {
        scopeStore.entries.first { $0.id == selectedScopeID }
    }

    // MARK: - Body

    /// The root HSplitView layout with sheet bindings.
    var body: some View {
        HSplitView {
            MigrationScopeListView(
                scopes: scopeStore.entries,
                selectedScopeID: $selectedScopeID,
                onAdd: { isAddScopePresented = true },
                onSetEnabled: setEnabled,
                onDelete: delete
            )
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)

            MigrationScopeDetailView(
                scope: selectedScope,
                onEdit: prepareEdit
            )
            .frame(minWidth: 360, idealWidth: 520, maxWidth: 900)
        }
        .sheet(isPresented: $isAddScopePresented) {
            AddScopeSheet(
                isPresented: $isAddScopePresented,
                authentication: authentication
            )
            .environment(overlayGate)
        }
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
        .onChange(of: scopeStore.entries) { _, newEntries in
            if let id = selectedScopeID,
               !newEntries.contains(where: { $0.id == id }) {
                selectedScopeID = nil
            }
        }
    }

    // MARK: - Actions

    /// Flips the enabled state via the store (observed by RunnerStore automatically).
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

    /// Fetches preferences asynchronously then presents the edit sheet.
    ///
    /// `isPreparingEdit` is set synchronously before the `Task` is created so
    /// any second Edit tap that arrives during the async fetch is blocked at the
    /// guard, even though `scopeEditPresentation` is still `nil` at that point.
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
