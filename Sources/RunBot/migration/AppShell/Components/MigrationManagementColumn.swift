// MigrationManagementColumn.swift
// RunBot

import SwiftUI

// MARK: - MigrationManagementColumn

/// Shared column container for management split-view panes (Scopes, Local runners).
/// Renders a 44-pt header with the column title on the left and an Add action on
/// the right, a divider, then the caller-provided content.
///
/// Use for any pane that owns a top-level Add action. The read-only workflow
/// hierarchy and step-log panes render without a header (#2880).
struct MigrationManagementColumn<Content: View>: View {
    /// The column heading displayed in the header bar.
    let title: String
    /// Label for the Add button shown at the trailing edge of the header.
    let addTitle: String
    /// Called when the Add button is tapped.
    let onAdd: () -> Void
    /// The pane body content.
    let content: Content

    /// Creates a management column with a title, add action, and view-builder content.
    init(
        title: String,
        addTitle: String,
        onAdd: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.addTitle = addTitle
        self.onAdd = onAdd
        self.content = content()
    }

    /// The column layout: header with Add action, divider, content.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 12)

                Button(addTitle, systemImage: "plus", action: onAdd)
                    .font(.system(size: 13, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
