// SettingsView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showWideRow = false

    var body: some View {
        let _ = print("[SettingsView] body evaluated — isSheetPresented=\(appState.isSheetPresented) showWideRow=\(showWideRow) gate=\(overlayGate.hasActiveOverlay)")
        @Bindable var appState = appState
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings").font(.headline).frame(maxWidth: .infinity, alignment: .center)
            Divider()

            Toggle("Show wide row", isOn: $showWideRow)
            if showWideRow {
                Text("← this row is intentionally wide to drive a horizontal resize →")
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize()
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Scenario 1
            Button("Open sheet") {
                print("[SettingsView] Open sheet tapped — setting isSheetPresented=true")
                appState.isSheetPresented = true
            }
            .mbkSheet(isPresented: $appState.isSheetPresented) {
                SheetView()
                    .environment(appState)
                    .environment(overlayGate)
            }

            // Scenario 2
            Button("Pick folder") {
                print("[SettingsView] Pick folder tapped — gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                mbkOpenFilePicker(overlayGate: overlayGate) { url in
                    print("[SettingsView] mbkOpenFilePicker completion — url=\(String(describing: url)) isSheetPresented=\(appState.isSheetPresented)")
                    appState.pickedURL = url
                }
            }
            if let path = appState.pickedURL?.path {
                Text(path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            // Scenario 3
            GroupBox("Alert from popover") {
                Button("Show alert") {
                    print("[SettingsView] Show alert tapped")
                    appState.showAlert = true
                }
                Text("Alert should appear. Popover stays alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .mbkAlert(
                "Simulated Error",
                isPresented: $appState.showAlert
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error shown from the popover view.")
            }

            Divider()
            Button("← Back") {
                print("[SettingsView] Back tapped")
                appState.route = .main
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()
        .onAppear    { print("[SettingsView] onAppear  isSheetPresented=\(appState.isSheetPresented) gate=\(overlayGate.hasActiveOverlay)") }
        .onDisappear { print("[SettingsView] onDisappear isSheetPresented=\(appState.isSheetPresented) gate=\(overlayGate.hasActiveOverlay)") }
    }
}
