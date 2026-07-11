// Views/SettingsView.swift
// RunBotSpike - spike/swiftui-nav-sheet

import SwiftUI

struct NavSheetSettingsView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Divider()

            GroupBox("Settings counter (persists on hide)") {
                HStack {
                    Text("\(appState.settingsCounter)").monospacedDigit().frame(minWidth: 24)
                    Spacer()
                    Button("+1") {
                        appState.settingsCounter += 1
                        log("SettingsView", "settingsCounter=\(appState.settingsCounter)")
                    }
                }
            }

            GroupBox("Toggle (persists on hide)") {
                Toggle("Enable something", isOn: $appState.settingsToggle)
                    .onChange(of: appState.settingsToggle) { _, v in
                        log("SettingsView", "toggle=\(v)")
                    }
            }

            GroupBox(".sheet (with alert + picker inside)") {
                Button("Open sheet...") {
                    log("SettingsView", "opening sheet")
                    appState.showSettingsSheet = true
                }
                Label(
                    appState.showSettingsSheet ? "Sheet is open" : "Sheet is closed",
                    systemImage: appState.showSettingsSheet ? "checkmark.circle.fill" : "xmark.circle"
                )
                .foregroundStyle(appState.showSettingsSheet ? .green : .secondary)
                .font(.caption)
            }
            .anchoredSheet(isPresented: $appState.showSettingsSheet, overlayCount: $appState.overlayCount) {
                NavSheetSheetView()
                    .environment(appState)
            }

            GroupBox("File picker (from settings)") {
                Button("Choose folder...") {
                    openFilePicker(target: .popover, appState: appState)
                }
                if !appState.pickedFolderPath.isEmpty {
                    Text(appState.pickedFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                } else {
                    Text("No folder picked yet").font(.caption).foregroundStyle(.secondary)
                }
            }

            Button("Back") {
                log("Nav", "route: settings -> main")
                appState.route = .main
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(width: 320)
    }
}
