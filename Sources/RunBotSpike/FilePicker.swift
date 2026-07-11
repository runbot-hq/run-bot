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
//   which keeps it anchored and — crucially — makes win.sheets non-empty while
//   it is open so popoverShouldClose blocks dismiss (see AppDelegate.swift).
//
// WINDOW RESOLUTION:
//   - Popover context: the nonactivatingPanel window (the popover's own window).
//   - Sheet context: the borderless child window that AnchoredSheet.swift
//     attached via addChildWindow. If for some reason that child isn't found,
//     fall back to the popover window itself.

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
    // beginSheetModal attaches the panel as a sheet to `window`, which:
    //   1. Keeps it visually anchored to the right window.
    //   2. Adds it to win.sheets so popoverShouldClose sees it and blocks dismiss.
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        log("FilePicker", "[\(label)] picked=\(url.path)")
        switch target {
        case .popover: appState.pickedPath = url.path
        case .sheet:   appState.sheetPickedPath = url.path
        }
    }
}
