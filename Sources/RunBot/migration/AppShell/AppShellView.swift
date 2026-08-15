// AppShellView.swift
// RunBot

import SwiftUI

/// Root two-column navigation shell for the windowed RunBot app.
/// Migration step 1 (#2797/#2799): intentionally static — no routing state.
struct AppShellView: View {
    /// The top-level split-view layout.
    var body: some View {
        NavigationSplitView {
            AppSidebarView()
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220,
                    max: 280
                )
        } detail: {
            AppDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }
}
