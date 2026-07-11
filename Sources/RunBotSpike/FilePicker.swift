// FilePicker.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Spike scenario 2: verify NSOpenPanel works when called from two contexts:
//   a) directly from the popover (SettingsView)
//   b) from inside the SwiftUI sheet (SheetView)
//
// WHY MANUAL WINDOW LOOKUP:
//   NSOpenPanel.runModal() blocks the main thread and ignores the popover.
//   beginSheetModal(for:) attaches the panel as a sheet to a specific window,
//   which keeps it visually anchored.
//
// WHY appState.hasActiveOverlay IS SET HERE:
//   The dismiss gate (popoverShouldClose in AppDelegate) reads hasActiveOverlay.
//   We set it to true before opening the panel and clear it in the completion
//   handler. This is parallel to what anchoredSheet does for SwiftUI sheets —
//   same contract, same flag, no special-casing needed in AppDelegate.
//
//   We do NOT rely on win.sheets being non-empty for this (even though
//   beginSheetModal does add to win.sheets), because keeping the dismiss gate
//   in one place (hasActiveOverlay) is cleaner than having AppDelegate inspect
//   both win.sheets and win.childWindows.
//
// WINDOW RESOLUTION:
//   - Popover context: the nonactivatingPanel window (the popover's own window).
//   - Sheet context: the borderless child window that AnchoredSheet.swift
//     attached via addChildWindow. Falls back to the popover window if not found.

import AppKit

enum PickerTarget { case popover, sheet }

@MainActor
func openFilePicker(target: PickerTarget, appState: NavSheetAppState) {
    let label = target == .popover ? "popover" : "sheet"

    let popoverWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    })
    // The sheet window is a visible child of the popover window added by
    // AnchoredSheet.swift. It may not exist if the sheet hasn't opened yet.
    let sheetChildWindow = popoverWindow?.childWindows?.first(where: { $0.isVisible })

    let window: NSWindow?
    switch target {
    case .popover: window = popoverWindow
    case .sheet:   window = sheetChildWindow ?? popoverWindow
    }

    guard let window else {
        log("FilePicker", "[\(label)] no window found, aborting")
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"

    // Set the dismiss gate before opening — popoverShouldClose may fire
    // during the panel's lifetime and must see the flag already set.
    appState.hasActiveOverlay = true
    log("FilePicker", "[\(label)] hasActiveOverlay=true")

    // beginSheetModal attaches the panel as a sheet to `window`, keeping it
    // visually anchored to the right window.
    panel.beginSheetModal(for: window) { response in
        // Clear the gate whether the user picked or cancelled.
        appState.hasActiveOverlay = false
        log("FilePicker", "[\(label)] hasActiveOverlay=false")
        guard response == .OK, let url = panel.url else { return }
        log("FilePicker", "[\(label)] picked=\(url.path)")
        switch target {
        case .popover: appState.pickedPath = url.path
        case .sheet:   appState.sheetPickedPath = url.path
        }
    }
}
