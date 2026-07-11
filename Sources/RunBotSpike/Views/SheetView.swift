// Views/SheetView.swift
// RunBotSpike
//
// Scenario 2 continued — file picker from inside the sheet.
// "Pick folder (sheet)" calls mbkOpenFilePicker(target: .sheet), which
// attaches NSOpenPanel to the child window AnchoredSheet wired up.

import SwiftUI
import MenuBarKit

struct SheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            Button("Pick folder (sheet)") {
                mbkOpenFilePicker(target: .sheet, overlayGate: overlayGate) { url in
                    appState.sheetPickedPath = url?.path ?? ""
                }
            }
            if !appState.sheetPickedPath.isEmpty {
                Text(appState.sheetPickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
