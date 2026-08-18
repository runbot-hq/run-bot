// MigrationScopeDetailView.swift
// RunBot

import RunBotCore
import SwiftUI

// MARK: - MigrationScopeDetailView

/// Settings-style detail column for the Scopes section. (#2907)
///
/// Resolves the selected scope live from `ScopeStore` so the monitoring
/// row stays synchronised with the list toggle without a duplicate control.
@MainActor
struct MigrationScopeDetailView: View {

    // MARK: - Inputs

    /// Live scope store — detail resolves its entry from this on every render.
    let scopeStore: ScopeStore
    /// Shell-owned selection ID.
    let selectedScopeID: ScopeEntry.ID?

    // MARK: - Derived

    /// Always-current entry for the selection, or `nil` when nothing is selected.
    private var scope: ScopeEntry? {
        scopeStore.entries.first { $0.id == selectedScopeID }
    }

    // MARK: - Body

    var body: some View {
        if let scope {
            detailBody(scope)
        } else {
            MigrationColumnPlaceholder(
                title: "Select a scope",
                systemImage: "scope"
            )
        }
    }

    // MARK: - Detail body

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
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .topLeading)
        }
    }

    // MARK: - Sections

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

    // MARK: - Layout helpers

    private func detailSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))

            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(Color.rbSettingsCardBackground)
            )
        }
    }

    private func detailRow(
        title: String,
        description: String,
        value: String,
        valueColor: Color = Color.secondary
    ) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 72)
    }

    private func copyableDetailRow(
        title: String,
        description: String,
        value: String
    ) -> some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(description)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy to clipboard")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 72)
    }

    private func rowDivider() -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.12))
            .frame(height: 1)
            .padding(.horizontal, 20)
    }
}
