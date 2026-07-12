// SettingsView.swift
// RunBotSpike
//
// Exercises all scenarios:
//
//   Scenario 1 — Sheet anchors + blocks outside-click dismiss:
//     "Open sheet" presents via .mbkSheet(), which wires the SwiftUI sheet
//     window as a child of the popover window and gates dismiss.
//
//   Scenario 2 — File picker from popover level:
//     "Pick folder (popover)" calls mbkOpenFilePicker(target: .popover).
//
//   Scenario 3 — Alert from popover level:
//     "Show alert" sets AppState.showAlert = true.
//     .alert is attached to the GroupBox (not the button).
//     .onChange(of: appState.showAlert) mirrors mbkOpenFilePicker's gate
//     pattern: gate=true when alert appears, gate=false when dismissed.
//     This prevents the outside-click monitor and workspace observer from
//     closing the popover while the alert is on screen.

import MenuBarKit
import SwiftUI

/// Settings view that exercises the sheet-anchoring, file-picker, and alert scenarios.
struct SettingsView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// Controls whether the anchored sheet is presented.
    @State private var showSheet = false

    var body: some View {
        @Bindable var appState = appState
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

            // Scenario 3
            GroupBox("Alert from popover") {
                Button("Show alert") { appState.showAlert = true }
                Text("Alert should appear. Popover stays alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error alert shown from the popover view.")
            }
            .onChange(of: appState.showAlert) { _, isShowing in
                // Gate the overlay while the alert is on screen so the
                // outside-click monitor and workspace observer don't close
                // the popover behind it. Mirrors mbkOpenFilePicker's pattern.
                overlayGate.hasActiveOverlay = isShowing
            }

            Divider()
            Button("← Back") { appState.route = .main }
        }
        .padding(16)
        .frame(width: 260)
    }
}
