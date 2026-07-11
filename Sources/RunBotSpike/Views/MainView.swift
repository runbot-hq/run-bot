// Views/MainView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Entry point shown when the popover first opens.
// Only job: navigate to SettingsView where the actual scenarios are exercised.
//
// WHY SO MINIMAL:
//   Earlier versions had a counter, a task-fire-count display, and a settings
//   toggle. All were removed — they tested things outside the scope of this
//   spike (state persistence, .task lifecycle) and added noise that made it
//   harder to verify the two scenarios we actually care about.

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
