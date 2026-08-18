// AppSidebarView.swift
// RunBot

import SwiftUI

/// Sidebar column with selectable navigation rows.
/// Status indicators and counts are added in later migration steps.
struct AppSidebarView: View {
    /// Binding to the shell's current section selection.
    @Binding var selection: AppSection?

    /// The selectable section list.
    var body: some View {
        List(AppSection.allCases, selection: $selection) { section in
            Label(section.title, systemImage: section.systemImage)
                .tag(section)
        }
        .navigationTitle("RunBot")
    }
}
