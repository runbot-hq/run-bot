// MainView.swift
// RunBotSpike

import SwiftUI

/// Landing view shown on first popover open. Navigates to `SettingsView`.
struct MainView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    /// The main view body — a single Settings button.
    var body: some View {
        VStack(spacing: 12) {
            Button("Settings →") { appState.route = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 260)
    }
}
