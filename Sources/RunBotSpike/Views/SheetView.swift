// Views/SheetView.swift
// RunBotSpike - spike/swiftui-nav-sheet

import SwiftUI

struct NavSheetSheetView: View {
    @Environment(NavSheetAppState.self) private var appState
    let onPickFolder: () -> Void

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Settings Sheet").font(.headline)

            GroupBox("Sheet counter") {
                HStack {
                    Text("\(appState.sheetCounter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") {
                        appState.sheetCounter += 1
                        log("SheetView", "sheetCounter=\(appState.sheetCounter)")
                    }
                }
            }

            GroupBox("Alert from sheet") {
                Button("Show error alert") {
                    log("SheetView", "showing alert")
                    appState.showSheetAlert = true
                }
                Text("Alert should appear, sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {
                    log("SheetView", "alert dismissed")
                }
            } message: {
                Text("This is a test error alert shown from inside a sheet.")
            }

            GroupBox("File picker from sheet") {
                Button("Choose folder...") {
                    log("SheetView", "requesting file picker from sheet")
                    onPickFolder()
                }
                if !appState.sheetPickedFolderPath.isEmpty {
                    Text(appState.sheetPickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No folder picked from sheet yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("Picker attaches to the sheet window itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Button("Dismiss") {
                log("SheetView", "dismissed by user")
                appState.showSettingsSheet = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 320)
    }
}
