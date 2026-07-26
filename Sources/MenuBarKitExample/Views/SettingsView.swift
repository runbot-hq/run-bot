// SettingsView.swift
// MenuBarKitExample

import MenuBarKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var showWideRow = false

    var body: some View {
        #if DEBUG
        let _ = print("[SettingsView] body evaluated — isSheetPresented=\(appState.isSheetPresented) showWideRow=\(showWideRow) gate=\(overlayGate.hasActiveOverlay)")
        #endif
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
                #if DEBUG
                print("[SettingsView] Open sheet tapped — setting isSheetPresented=true")
                #endif
                appState.isSheetPresented = true
            }
            .mbkSheet(isPresented: $appState.isSheetPresented) {
                SheetView()
                    .environment(appState)
                    .environment(overlayGate)
            }

            // Scenario 2
            Button("Pick folder") {
                #if DEBUG
                print("[SettingsView] Pick folder tapped — gate=\(overlayGate.hasActiveOverlay) isSheetPresented=\(appState.isSheetPresented)")
                #endif
                mbkOpenFilePicker(overlayGate: overlayGate) { url in
                    #if DEBUG
                    print("[SettingsView] mbkOpenFilePicker completion — url=\(String(describing: url)) isSheetPresented=\(appState.isSheetPresented)")
                    #endif
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
                    #if DEBUG
                    print("[SettingsView] Show alert tapped")
                    #endif
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
                #if DEBUG
                print("[SettingsView] Back tapped")
                #endif
                appState.route = .main
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(16)
        .fixedSize()
        .onAppear {
            #if DEBUG
            print("[SettingsView] onAppear  isSheetPresented=\(appState.isSheetPresented) gate=\(overlayGate.hasActiveOverlay)")
            #endif
        }
        .onDisappear {
            #if DEBUG
            print("[SettingsView] onDisappear isSheetPresented=\(appState.isSheetPresented) gate=\(overlayGate.hasActiveOverlay)")
            #endif
        }
    }
}
