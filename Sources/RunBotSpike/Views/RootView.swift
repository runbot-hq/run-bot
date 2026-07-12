// RootView.swift
// RunBotSpike

import SwiftUI

/// Root container that switches between `MainView` and `SettingsView`
/// based on `AppState.route`.
struct RootView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState

    /// Renders `MainView` or `SettingsView` depending on the current route.
    var body: some View {
        switch appState.route {
        case .main:     MainView()
        case .settings: SettingsView()
        }
    }
}
