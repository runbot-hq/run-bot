// MigrationWorkflowColumn.swift
// RunBot

import SwiftUI

/// Shared pane container for workflow columns.
/// Provides a consistent native header and content layout across panes.
struct MigrationWorkflowColumn<Content: View>: View {
    /// The column heading displayed in the header bar.
    let title: String
    /// The pane body content.
    let content: Content

    /// Creates a column pane with a title and view-builder content.
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    /// The column layout: header, divider, content.
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)

                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
