// SheetView.swift
// RunBotSpike
//
// Scenario 2 continued — file picker from inside the sheet.
// "Pick folder (sheet)" calls mbkOpenFilePicker(target: .sheet), which
// attaches NSOpenPanel to the child window AnchoredSheet wired up.
//
// Scenario 3 — alert from inside the sheet.
// "Show error alert" sets AppState.showSheetAlert = true.
// .alert is attached to the GroupBox (not the button) — same pattern
// confirmed working in commit 902eacb. AppState owns the flag so it
// survives any view identity resets. No changes to PopoverController
// or MBKOverlayGate are needed — the alert is a system modal and
// AppKit handles it without involving the popover dismiss path.

import MenuBarKit
import SwiftUI

/// Sheet content view that exercises the file picker and alert from inside a child window.
struct SheetView: View {
    /// App state injected from the environment.
    @Environment(AppState.self) private var appState
    /// Overlay gate injected from the environment.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// SwiftUI dismiss action.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appState = appState
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            GroupBox("Alert from sheet") {
                Button("Show error alert") { appState.showSheetAlert = true }
                Text("Alert should appear. Sheet + popover stay alive.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .alert("Simulated Error", isPresented: $appState.showSheetAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("This is a test error alert shown from inside a sheet.")
            }

            GroupBox("File picker from sheet") {
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
            }

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
