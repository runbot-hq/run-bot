// Views/SettingsView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 1 — Sheet anchors + blocks outside-click dismiss:
//   "Open sheet" presents via .anchoredSheet(), which wires the SwiftUI sheet
//   window as a child of the popover window (see AnchoredSheet.swift). While
//   the sheet is open, clicking outside the popover should be blocked.
//
// Scenario 2 — File picker from popover level:
//   "Pick folder (popover)" calls openFilePicker(target: .popover) which attaches
//   NSOpenPanel as a sheet to the popover window. While it is open, clicking
//   outside should also be blocked.

import SwiftUI

struct NavSheetSettingsView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Scenario 1
            Button("Open sheet") { appState.showSheet = true }
            .anchoredSheet(isPresented: $appState.showSheet) {
                NavSheetSheetView().environment(appState)
            }

            // Scenario 2
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
