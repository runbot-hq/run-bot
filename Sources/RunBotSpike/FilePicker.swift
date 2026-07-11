// FilePicker.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Presents NSOpenPanel attached to the correct window.
//
// Window resolution strategy:
//   - popover window: the nonactivatingPanel window (NSPopover's host window)
//   - sheet window: a visible borderless child of the popover window
//
// NSApp.delegate is nil in a SwiftUI @main app with NSApplicationDelegateAdaptor,
// so windows are resolved directly from NSApp.windows instead.
//
// overlayCount is incremented before the panel opens and decremented in the
// completion handler so popoverShouldClose blocks dismiss while picker is open.

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
    appState.overlayCount += 1
    log("FilePicker", "[\(label)] overlayCount=\(appState.overlayCount)")
    panel.beginSheetModal(for: window) { response in
        appState.overlayCount -= 1
        log("FilePicker", "[\(label)] closed overlayCount=\(appState.overlayCount)")
        guard response == .OK, let url = panel.url else { return }
        log("FilePicker", "[\(label)] picked=\(url.path)")
        switch target {
        case .popover: appState.pickedFolderPath = url.path
        case .sheet:   appState.sheetPickedFolderPath = url.path
        }
    }
}
