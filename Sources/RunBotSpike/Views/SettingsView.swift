// Views/SettingsView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 2: sheet anchors + blocks dismiss
// Scenario 3: file picker from popover level

import SwiftUI

struct NavSheetSettingsView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Scenario 2
            Button("Open sheet") { appState.showSheet = true }
            .anchoredSheet(isPresented: $appState.showSheet) {
                NavSheetSheetView().environment(appState)
            }

            // Scenario 3
            Button("Pick folder (popover)") {
                openFilePicker(target: .popover, appState: appState)
            }
            if !appState.pickedPath.isEmpty {
                Text(appState.pickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()
            Button("← Back") { appState.route = .main }
        }
        .padding(16)
        .frame(width: 260)
    }
}
