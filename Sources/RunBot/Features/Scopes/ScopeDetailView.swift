// ScopeDetailView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - ScopeDetailView

/// Settings-style detail column for the Scopes section. (#2907)
///
/// Resolves the selected scope live from `ScopeStore` so the monitoring
/// row stays synchronised with the list toggle without a duplicate control.
@MainActor
struct ScopeDetailView: View {

    // MARK: - Inputs

    /// Live scope store — detail resolves its entry from this on every render.
    let scopeStore: ScopeStore
    /// Shell-owned selection ID.
    let selectedScopeID: ScopeEntry.ID?

    // MARK: - Derived

    /// Always-current entry for the selection, or `nil` when nothing is selected.
    /// Always-current scope entry resolved from the live store.
    private var scope: ScopeEntry? {
        scopeStore.entries.first { $0.id == selectedScopeID }
    }

    // MARK: - Body

    /// Shows the Settings-style detail when a scope is selected; placeholder otherwise.
    var body: some View {
        if let scope {
            detailBody(scope)
        } else {
            ColumnPlaceholder(
                title: "Select a scope",
                systemImage: "scope"
            )
        }
    }

    // MARK: - Detail body

    /// Full Settings-style detail layout for a resolved scope.
    @ViewBuilder
    private func detailBody(_ scope: ScopeEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(scope.displayName ?? scope.scope)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)

                scopeInformationSection(scope)
                monitoringSection(scope)
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 820, alignment: .topLeading)
        }
    }

    // MARK: - Sections

    /// 'Scope information' card section.
    private func scopeInformationSection(_ scope: ScopeEntry) -> some View {
        detailSection(title: "Scope information") {
            detailRow(
                title: "Scope",
                description: "Repository or organization monitored by RunBot.",
                value: scope.scope
            )
            rowDivider()
            detailRow(
                title: "Type",
                description: "Kind of GitHub scope being monitored.",
                value: scope.scope.contains("/") ? "Repository" : "Organization"
            )
            rowDivider()
            if let url = URL(string: "https://github.com/" + scope.scope) {
                copyableDetailRow(
                    title: "GitHub",
                    description: "View this scope on GitHub.",
                    value: url.absoluteString
                )
            }
        }
    }

    /// 'Monitoring' card section showing current poll state as a read-only value.
    private func monitoringSection(_ scope: ScopeEntry) -> some View {
        detailSection(title: "Monitoring") {
            detailRow(
                title: "Monitor this scope",
                description: scope.isEnabled
                    ? "RunBot actively polls this scope for runner status."
                    : "RunBot does not poll this scope for runner status.",
                value: scope.isEnabled ? "Active" : "Paused",
                valueColor: scope.isEnabled ? Color.rbSuccess : Color.secondary
            )
        }
    }
}
