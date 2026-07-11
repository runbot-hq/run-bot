// Views/MainView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Entry point shown when the popover first opens.
// Only job: navigate to SettingsView where the actual scenarios are tested.

import SwiftUI

struct NavSheetMainView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        VStack(spacing: 12) {
            Button("Settings →") { appState.route = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .frame(width: 260)
    }
}
