// Views/SheetView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 3: file picker from inside sheet

import SwiftUI

struct NavSheetSheetView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            // Scenario 3
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
