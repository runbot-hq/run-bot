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
// WHY hasActiveOverlay IS SET BEFORE beginSheetModal:
//   popoverShouldClose can fire at any point, including during the brief window
//   between when we decide to open the panel and when beginSheetModal returns.
//   Setting the gate before the call ensures the dismiss gate is armed for the
//   entire panel lifetime with no race.
//
//   If beginSheetModal itself fails silently (rare edge case), the gate stays
//   true for the session. This is safe: MBKPopoverController.popoverDidClose
//   resets the gate unconditionally as a safety net, so the worst outcome is
//   that dismiss is blocked until the user closes and reopens the popover.
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
    // TODO: When porting to the main app, strengthen this predicate — the main
    // app may have other visible child windows. Use the same discriminator
    // settled on for AnchoredSheet.anchorSheetWindow() (see that file's
    // SHEET WINDOW DISCRIMINATOR note) so both lookups stay in sync.
    let sheetChildWindow = popoverWindow?.childWindows?.first(where: { $0.isVisible })

    let window: NSWindow?
    switch target {
    case .popover: window = popoverWindow
    case .sheet:   window = sheetChildWindow ?? popoverWindow
    }

    guard let window else {
        mbkLog("FilePicker", "[\(label)] no window found, aborting")
        // Gate is NOT set yet at this point — early exit is clean, no reset needed.
        return
    }

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"

    // Arm the dismiss gate before opening — see WHY hasActiveOverlay IS SET
    // BEFORE beginSheetModal in the file header.
    overlayGate.hasActiveOverlay = true
    mbkLog("FilePicker", "[\(label)] hasActiveOverlay=true")

    panel.beginSheetModal(for: window) { response in
        overlayGate.hasActiveOverlay = false
        mbkLog("FilePicker", "[\(label)] hasActiveOverlay=false")
        completion(response == .OK ? panel.url : nil)
    }
}
