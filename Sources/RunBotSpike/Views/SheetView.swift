// Views/SheetView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 2 — File picker from inside the sheet:
//   "Pick folder (sheet)" calls openFilePicker(target: .sheet), which looks for
//   the child window AnchoredSheet.swift attached and opens NSOpenPanel against
//   that window. Tests that the picker can be driven from a window that is itself
//   a child of the popover window, not the popover window directly.

import SwiftUI

struct NavSheetSheetView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            // Scenario 2
            Button("Pick folder (sheet)") {
                openFilePicker(target: .sheet, appState: appState)
            }
            if !appState.sheetPickedPath.isEmpty {
                Text(appState.sheetPickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Button("Dismiss") { appState.showSheet = false }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
