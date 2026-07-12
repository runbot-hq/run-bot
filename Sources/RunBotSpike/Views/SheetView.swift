// SheetView.swift
// RunBotSpike
//
// Scenario 2 continued — file picker from inside the sheet.
// "Pick folder (sheet)" calls mbkOpenFilePicker(target: .sheet), which
// attaches NSOpenPanel to the child window AnchoredSheet wired up.

import MenuBarKit
import SwiftUI

/// Sheet content view that exercises the file picker from inside a child window.
struct SheetView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// SwiftUI dismiss action.
    @Environment(\.dismiss) private var dismiss

    /// The sheet body — a folder picker and a dismiss button.
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
