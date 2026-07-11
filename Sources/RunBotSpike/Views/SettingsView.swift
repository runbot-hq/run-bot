// Views/SettingsView.swift
// RunBotSpike
//
// Exercises both scenarios:
//
//   Scenario 1 — Sheet anchors + blocks outside-click dismiss:
//     "Open sheet" presents via .mbkSheet(), which wires the SwiftUI sheet
//     window as a child of the popover window and gates dismiss.
//
//   Scenario 2 — File picker from popover level:
//     "Pick folder (popover)" calls mbkOpenFilePicker(target: .popover).

import SwiftUI
import MenuBarKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Scenario 1
            Button("Open sheet") { showSheet = true }
                .mbkSheet(isPresented: $showSheet, overlayGate: overlayGate) {
                    SheetView()
                        .environment(appState)
                        .environment(overlayGate)
                }

            // Scenario 2
            Button("Pick folder (popover)") {
                mbkOpenFilePicker(target: .popover, overlayGate: overlayGate) { url in
                    appState.pickedPath = url?.path ?? ""
                }
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
