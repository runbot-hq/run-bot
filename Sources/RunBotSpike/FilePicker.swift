// FilePicker.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// File picker via NSOpenPanel.beginSheetModal.
// Attached to either the popover window or the sheet child window.
// overlayCount is incremented/decremented around the panel lifetime
// so the dismiss guard blocks outside-click close while picker is open.

import AppKit

enum PickerTarget { case popover, sheet }

@MainActor
func openFilePicker(
    attachedTo target: PickerTarget,
    popoverWindow: NSWindow?,
    sheetWindow: NSWindow?,
    appState: NavSheetAppState
) {
    let label = target == .popover ? "popover" : "sheet"
    let window: NSWindow?
    switch target {
    case .popover: window = popoverWindow
    case .sheet:   window = sheetWindow ?? popoverWindow
    }
    guard let window else {
        log("FilePicker", "[\(label)] no window found, aborting")
        return
    }
    log("FilePicker", "[\(label)] opening panel attached to \(NSStringFromClass(type(of: window)))")
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = target == .sheet ? "Pick folder from inside sheet" : "Select a folder"
    panel.prompt = "Select"
    appState.overlayCount += 1
    log("FilePicker", "[\(label)] beginSheetModal overlayCount=\(appState.overlayCount)")
    panel.beginSheetModal(for: window) { response in
        appState.overlayCount -= 1
        log("FilePicker", "[\(label)] closed response=\(response.rawValue) overlayCount=\(appState.overlayCount)")
        guard response == .OK, let url = panel.url else { return }
        log("FilePicker", "[\(label)] picked=\(url.path)")
        switch target {
        case .popover: appState.pickedFolderPath = url.path
        case .sheet:   appState.sheetPickedFolderPath = url.path
        }
    }
}
