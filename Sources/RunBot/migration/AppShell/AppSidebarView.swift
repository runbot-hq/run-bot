// AppSidebarView.swift
// RunBot

import SwiftUI

/// Static sidebar column for the migration shell.
/// Placeholder only — routing rows are added in PR 2.
struct AppSidebarView: View {
    /// The sidebar list content.
    var body: some View {
        List {
            Text("RunBot")
                .foregroundStyle(.secondary)
        }
        .navigationTitle("RunBot")
    }
}
