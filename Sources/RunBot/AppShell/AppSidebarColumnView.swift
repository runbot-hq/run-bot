// AppSidebarColumnView.swift
// RunBot

import SwiftUI

/// Sidebar column composed of a scrollable navigation list and a pinned metrics footer.
///
/// The navigation `List` and `SidebarMetricsCard` are separated by a `Divider`
/// inside a `VStack` so metrics stay fixed at the bottom regardless of selection.
/// Navigation can shrink and scroll independently when the window is short.
struct AppSidebarColumnView: View {
    /// Binding to the shell's current destination selection.
    @Binding var selection: AppDestination?

    /// The sidebar layout: scrollable navigation list above a pinned metrics footer.
    var body: some View {
        VStack(spacing: 0) {
            List(AppDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .listStyle(.sidebar)

            Divider()

            SidebarMetricsCard()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .navigationTitle("RunBot")
    }
}
