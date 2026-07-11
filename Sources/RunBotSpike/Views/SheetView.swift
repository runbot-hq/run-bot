// Views/SheetView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Scenario 2 (continued) — File picker from inside the sheet:
//   "Pick folder (sheet)" calls openFilePicker(target: .sheet), which looks
//   for the child window AnchoredSheet.swift attached via addChildWindow, and
//   opens NSOpenPanel against that window via beginSheetModal.
//
//   This tests a specific question: can NSOpenPanel be driven from a window
//   that is itself a child of the popover window (not the popover directly)?
//   Verify: panel opens, path appears below button after selection.
//
// WHY @Environment(\.dismiss) FOR DISMISS:
//   showSheet is now @State private in SettingsView — the view that owns this
//   sheet. SheetView has no access to that binding. @Environment(\.dismiss) is
//   the correct SwiftUI pattern for a sheet to dismiss itself without needing
//   a reference to the parent's binding.
//
//   Earlier version used appState.showSheet = false, which required showSheet
//   to live on AppState. That was the wrong coupling — sheet presentation state
//   belongs to the owning view, not global state.
//
// WHY .keyboardShortcut(.cancelAction) ON DISMISS:
//   Pressing Escape should dismiss the sheet. SwiftUI does not wire this
//   automatically on macOS for non-fullscreen sheets. .cancelAction maps to
//   the Escape key and calls the button action.

import SwiftUI

struct NavSheetSheetView: View {
    @Environment(NavSheetAppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Sheet").font(.headline)

            // Scenario 2 — file picker from inside the sheet
            Button("Pick folder (sheet)") {
                openFilePicker(target: .sheet, appState: appState)
            }
            if !appState.sheetPickedPath.isEmpty {
                // Confirmation that the picker ran from the sheet window.
                Text(appState.sheetPickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Button("Dismiss") { dismiss() }
                .buttonStyle(.borderedProminent)
                // Escape key dismisses — not automatic on macOS non-fullscreen sheets.
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 280)
    }
}
