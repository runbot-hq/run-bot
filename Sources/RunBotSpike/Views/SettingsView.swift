// Views/SettingsView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Exercises both spike scenarios:
//
// Scenario 1 — Sheet anchors + blocks outside-click dismiss:
//   "Open sheet" presents via .anchoredSheet(), which wires the SwiftUI sheet
//   window as a child of the popover window (see AnchoredSheet.swift) and sets
//   appState.hasActiveOverlay while the sheet is open.
//   Verify: click outside while sheet is open — popover must not close.
//
// Scenario 2 — File picker from popover level:
//   "Pick folder (popover)" calls openFilePicker(target: .popover), which
//   attaches NSOpenPanel as a sheet to the popover window via beginSheetModal
//   and sets appState.hasActiveOverlay while the panel is open.
//   Verify: click outside while panel is open — popover must not close.
//   Verify: selected path appears below the button after dismissal.
//
// WHY showSheet IS @State HERE AND NOT ON AppState:
//   Sheet presentation state belongs to the view that owns the sheet. Storing
//   it on AppState would mean every new sheet in any view requires an AppState
//   change — wrong coupling. The anchoredSheet modifier bridges local @State
//   to appState.hasActiveOverlay automatically; this view never touches AppState
//   for sheet lifecycle.
//
// WHY @Bindable var appState = appState:
//   @Environment gives a read-only reference. @Bindable unwraps it into a
//   mutable binding so we can pass $appState.showSheet to .anchoredSheet().
//   Required by the Observation framework ('@Observable' classes).

import SwiftUI

struct NavSheetSettingsView: View {
    @Environment(NavSheetAppState.self) private var appState
    // Sheet state is local — this view owns this sheet, not AppState.
    @State private var showSheet = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Settings").font(.headline)
            Divider()

            // Scenario 1 — sheet anchoring + dismiss blocking
            Button("Open sheet") { showSheet = true }
            .anchoredSheet(isPresented: $showSheet) {
                NavSheetSheetView().environment(appState)
            }

            // Scenario 2 — file picker from popover
            Button("Pick folder (popover)") {
                openFilePicker(target: .popover, appState: appState)
            }
            if !appState.pickedPath.isEmpty {
                // Confirmation that the picker ran and returned a value.
                Text(appState.pickedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
            }

            Divider()
            Button("← Back") { appState.route = .main }
        }
        .padding(16)
        .frame(width: 260)
    }
}
