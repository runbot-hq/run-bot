// FilePicker.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Presents NSOpenPanel attached to the correct window.
//
// Window resolution:
//   - popover window: the nonactivatingPanel window
//   - sheet window: a visible borderless child of the popover window
//
// No overlayCount needed — while NSOpenPanel is open it is attached as a sheet
// to the window, so win.sheets is non-empty and popoverShouldClose blocks.

import AppKit

enum PickerTarget { case popover, sheet }

@MainActor
func openFilePicker(target: PickerTarget, appState: NavSheetAppState) {
    let label = target == .popover ? "popover" : "sheet"

    let popoverWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    })
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
    log("FilePicker", "[\(label)] opening panel on \(NSStringFromClass(type(of: window)))")

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = target == .sheet ? "Pick folder from inside sheet" : "Select a folder"
    panel.prompt = "Select"
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        log("FilePicker", "[\(label)] picked=\(url.path)")
        switch target {
        case .popover: appState.pickedFolderPath = url.path
        case .sheet:   appState.sheetPickedFolderPath = url.path
        }
    }
}
