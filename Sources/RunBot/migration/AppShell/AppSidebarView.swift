// AppSidebarView.swift
// RunBot

import SwiftUI

/// Sidebar column composed of a scrollable navigation list and a pinned metrics footer.
///
/// The navigation `List` and `SidebarMetricsView` are separated by a `Divider`
/// inside a `VStack` so metrics stay fixed at the bottom regardless of selection.
/// Navigation can shrink and scroll independently when the window is short.
struct AppSidebarView: View {
    /// Binding to the shell's current section selection.
    @Binding var selection: AppSection?

    /// The sidebar layout: scrollable navigation list above a pinned metrics footer.
    var body: some View {
        VStack(spacing: 0) {
            List(AppSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)

            Divider()

            SidebarMetricsView()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .navigationTitle("RunBot")
    }
}
