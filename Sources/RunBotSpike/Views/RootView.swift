// Views/RootView.swift
// RunBotSpike

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.route {
        case .main:     MainView()
        case .settings: SettingsView()
        }
    }
}
