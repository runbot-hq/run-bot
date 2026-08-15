// AppShellView.swift
// RunBot

import SwiftUI

/// Root two-column navigation shell.
/// Owns the top-level sidebar selection; sidebar routing is wired here.
struct AppShellView: View {
    /// Currently selected sidebar section. Defaults to Workflows.
    @State private var selection: AppSection? = .workflows

    /// The top-level split-view layout.
    var body: some View {
        NavigationSplitView {
            AppSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: 220,
                    ideal: 240,
                    max: 300
                )
        } detail: {
            AppDetailView(selection: selection)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1_120, minHeight: 480)
    }
}
