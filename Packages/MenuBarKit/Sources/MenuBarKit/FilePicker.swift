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
//     via addChildWindow. Falls back to the popover window if not found, with
//     a runtime WARNING log. See SILENT FALLBACK NOTE below.
//
// SILENT FALLBACK NOTE (.sheet case):
//   If the sheet child window is not yet attached when mbkOpenFilePicker is
//   called (e.g. fast-tap sequence before MBKAnchoredSheet has completed its
//   two-hop anchor), the .sheet case falls back to the popover window. In the
//   spike this is acceptable — the picker still opens, just not sheet-anchored.
//   In the main app this is a silent UX degradation the user may notice.
//
//   TODO (migration PR): decide explicitly between two strategies and document
//   the choice in the PR description:
//     A. Silent fallback (current): log WARNING, open on popover, continue.
//        Acceptable if fast-tap is rare and the degraded UX is tolerable.
//     B. Abort: log WARNING, skip opening, return nil to completion.
//        Safer — no picker opens in a degraded state, caller can retry.
//   Leaning toward B (abort) to avoid silent UX degradation, but the call
//   site in LocalRunnersView must handle the nil completion gracefully.
//
// beginSheetModal COMPLETION — WHY Task { @MainActor }:
//   NSOpenPanel.beginSheetModal delivers its completion on the main thread, but
//   this guarantee is informal (not expressed in the Swift type system). The
//   completion mutates overlayGate.hasActiveOverlay (@MainActor-isolated) and
//   calls back into caller-supplied code that may also touch actor-isolated state.
//   Wrapping in Task { @MainActor } makes the actor hop explicit and
//   compiler-enforced, rather than relying on AppKit's undocumented delivery
//   guarantee. This is the correct Swift 6 pattern.
//
// sheetChildWindow PREDICATE — WHY it is intentionally weak:
//   The predicate `childWindows?.first(where: { $0.isVisible })` selects the
//   first visible child window. This is correct for the spike because
//   MBKPopoverController has at most one child window at any time.
//
//   It is intentionally NOT strengthened to match by styleMask or window class
//   for two reasons:
//
//   1. NSOpenPanel borderless-window race: NSOpenPanel presented via
//      beginSheetModal also creates a borderless window. During a
//      close-then-immediately-reopen sequence, an NSOpenPanel window could be
//      borderless+key at the moment the predicate fires — a stronger borderless
//      match would hit it instead of the sheet window. Using isVisible on the
//      childWindows list (not NSApp.windows) scopes the search to windows
//      already parented to the popover, which the NSOpenPanel window is not
//      at that point in its lifecycle.
//
//   2. NSHostingController<AnyView> was tried as a stronger discriminator and
//      does not match SwiftUI's internal sheet window — see AnchoredSheet.swift
//      SHEET WINDOW DISCRIMINATOR for the full history.
//
//   TODO (migration PR): When porting to the main app, strengthen this predicate
//   further — the main app may have multiple visible child windows simultaneously
//   (e.g. during sheet + NSOpenPanel overlap). Use the same discriminator
//   settled on for AnchoredSheet.anchorSheetWindow() so both lookups stay in sync.

import AppKit

/// Specifies which window context the file picker should attach to.
public enum MBKPickerTarget {
    /// Attach the picker to the popover window directly.
    case popover
    /// Attach the picker to the sheet child window (falls back to popover if absent).
    case sheet
}

/// Opens a directory picker anchored to the appropriate window.
/// The completion closure is called on the main actor with the selected URL,
/// or nil if the user cancelled.
@MainActor
public func mbkOpenFilePicker(
    target: MBKPickerTarget,
    overlayGate: MBKOverlayGate,
    completion: @escaping @MainActor (URL?) -> Void
) {
    let label = target == .popover ? "popover" : "sheet"

    let popoverWindow = NSApp.windows.first(where: {
        $0.styleMask.contains(.nonactivatingPanel)
    })
    // Intentionally weak predicate — see sheetChildWindow PREDICATE in the
    // file header before attempting to strengthen this.
    let sheetChildWindow = popoverWindow?.childWindows?.first(where: { $0.isVisible })

    let window: NSWindow?
    switch target {
    case .popover:
        window = popoverWindow
    case .sheet:
        if let child = sheetChildWindow {
            window = child
        } else {
            // Sheet child window not yet attached — see SILENT FALLBACK NOTE in
            // the file header. Logs a WARNING so this path is visible at runtime.
            // TODO (migration PR): consider aborting (return nil) instead of
            // falling back, to avoid silent UX degradation.
            mbkLog("FilePicker", "[sheet] WARNING: no child window found, falling back to popover window")
            window = popoverWindow
        }
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
        // Explicit @MainActor hop — see beginSheetModal COMPLETION in the file header.
        Task { @MainActor in
            overlayGate.hasActiveOverlay = false
            mbkLog("FilePicker", "[\(label)] hasActiveOverlay=false")
            completion(response == .OK ? panel.url : nil)
        }
    }
}
