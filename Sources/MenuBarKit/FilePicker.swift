// FilePicker.swift
// MenuBarKit
//
// Presents NSOpenPanel anchored to the correct window (popover or sheet child)
// via beginSheetModal, and manages overlayGate.hasActiveOverlay for the
// duration of the panel's lifetime.
//
// WHY beginSheetModal INSTEAD OF runModal:
//   NSOpenPanel.runModal() blocks the main thread and ignores the popover.
//   beginSheetModal attaches the panel as a sheet to a specific window,
//   keeping it visually anchored.
//
// WINDOW RESOLUTION:
//   - .popover context: the nonactivatingPanel window (the popover's own window).
//   - .sheet context: the visible child window that MBKAnchoredSheet attached
//     via addChildWindow. Falls back to the popover window if not found.

import AppKit

public enum MBKPickerTarget {
    case popover
    case sheet
}

/// Opens a directory picker anchored to the appropriate window.
/// The completion closure is called on the main actor with the selected URL,
/// or nil if the user cancelled.
@MainActor
public func mbkOpenFilePicker(
    target: MBKPickerTarget,
    overlayGate: MBKOverlayGate,
    completion: @escaping (URL?) -> Void
) {
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
        mbkLog("FilePicker", "[\(label)] no window found, aborting")
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"

    // Arm the dismiss gate before opening — popoverShouldClose may fire
    // during the panel's lifetime.
    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "[\(label)] hasActiveOverlay=true")

    panel.beginSheetModal(for: window) { response in
        overlayGate.hasActiveOverlay = false
        mbkLog("FilePicker", "[\(label)] hasActiveOverlay=false")
        completion(response == .OK ? panel.url : nil)
    }
}
