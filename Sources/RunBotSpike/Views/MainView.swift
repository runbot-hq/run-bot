// Views/MainView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 1: counter must survive hide/show

import SwiftUI

struct NavSheetMainView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Text("Counter: \(appState.counter)")
                .font(.headline)
            Button("+1") { appState.counter += 1 }
            Divider()
            Button("Settings →") { appState.route = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 260)
    }
}
