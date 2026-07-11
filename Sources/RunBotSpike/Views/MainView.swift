// Views/MainView.swift
// RunBotSpike

import SwiftUI

struct MainView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Button("Settings →") { appState.route = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 260)
    }
}
