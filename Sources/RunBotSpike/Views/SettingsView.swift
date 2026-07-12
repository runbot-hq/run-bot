// SettingsView.swift
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

import MenuBarKit
import SwiftUI

/// Settings view that exercises the sheet-anchoring and file-picker scenarios.
struct SettingsView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// Controls whether the anchored sheet is presented.
    @State private var showSheet = false

    /// The settings view body — two scenario buttons and a path display.
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
