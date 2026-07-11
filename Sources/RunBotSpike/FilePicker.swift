// FilePicker.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Presents NSOpenPanel attached to the correct window.
// The delegate's popoverWindow / sheetWindow are resolved via the shared
// AppDelegate instance looked up from NSApp.delegate.
//
// overlayCount is incremented before the panel opens and decremented in the
// completion handler so popoverShouldClose blocks dismiss while picker is open.

import AppKit

enum PickerTarget { case popover, sheet }

@MainActor
func openFilePicker(target: PickerTarget, appState: NavSheetAppState) {
    guard let delegate = NSApp.delegate as? NavSheetAppDelegate else {
        log("FilePicker", "no delegate, aborting")
        return
    }
    let label = target == .popover ? "popover" : "sheet"
    let window: NSWindow?
    switch target {
    case .popover: window = delegate.popoverWindow
    case .sheet:   window = delegate.sheetWindow ?? delegate.popoverWindow
    }
    guard let window else {
        log("FilePicker", "[\(label)] no window found, aborting")
        return
    }
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.message = target == .sheet ? "Pick folder from inside sheet" : "Select a folder"
    panel.prompt = "Select"
    appState.overlayCount += 1
    log("FilePicker", "[\(label)] opening overlayCount=\(appState.overlayCount)")
    panel.beginSheetModal(for: window) { response in
        appState.overlayCount -= 1
        log("FilePicker", "[\(label)] closed overlayCount=\(appState.overlayCount)")
        guard response == .OK, let url = panel.url else { return }
        switch target {
        case .popover: appState.pickedFolderPath = url.path
        case .sheet:   appState.sheetPickedFolderPath = url.path
        }
    }
}
