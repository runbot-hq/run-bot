// FilePicker.swift
// MenuBarKit
//
// WHY panel.begin{} INSTEAD OF beginSheetModal:
//   beginSheetModal attaches NSOpenPanel as an AppKit sheet to the popover
//   hosting window. SwiftUI writes true back into any live .sheet(isPresented:)
//   binding on that window — corrupting isSheetPresented state.
//
// WHY panel.level = popoverWindow.level + 1, NOT addChildWindow:
//   addChildWindow causes two problems:
//   1. Clicking outside the app boundary dismisses the child panel.
//   2. hasSheetChildWindow counts childWindows and triggers forceClose.
//   .floating (level 3) is below the popover's nonactivatingPanel level.
//   Reading the popover's actual level and adding 1 guarantees the panel
//   is always on top.
//
// WHY panel.makeKeyAndOrderFront AFTER panel.begin (AND WHY THE TIMING IS SAFE):
//   panel.begin{} synchronously adds the panel to the window server and puts
//   it on screen before returning. The completion block fires later — only
//   when the user dismisses the panel. makeKeyAndOrderFront(nil) is therefore
//   called after the panel already has a valid window number and is visible;
//   there is no run-loop ordering hazard here. The panel is on screen, just
//   without key focus — because the nonactivatingPanel popover retains key
//   status after begin returns. makeKeyAndOrderFront transfers key focus to
//   the picker so the user sees it immediately. This was verified against the
//   alternative of relying solely on panel.level; level alone does not transfer
//   key focus on macOS 14+.
//   NSApp.activate is NOT called here — it would steal app focus from other
//   apps in menu-bar-only scenarios where the app has no Dock presence.
//
// WHY panel.orderOut AFTER COMPLETION:
//   NSOpenPanel windows accumulate in NSApp.windows without explicit orderOut.
//
// WHY gateWasAlreadyArmed / CONCURRENT OVERLAY SAFETY:
//   If called while a sheet is already open (gate=true), we must not clear
//   the gate on completion — the sheet is still holding it. We snapshot
//   the gate state before opening and only clear if we were the ones who
//   armed it. Mirrors the pattern in MBKAlertModifier.
//
// WHY hasFilePickerOverlay:
//   When a picker is open inside a sheet, the sheet child window is already
//   attached to the popover. The event monitor sees hwChildren=1 and calls
//   forceClose on every outside click — including clicks inside the picker.
//   hasFilePickerOverlay lets the monitor know a picker is active and skip
//   forceClose even when a sheet child is present.
//
// WHY Task { @MainActor } WRAPPING panel.begin COMPLETION:
//   NSOpenPanel.begin delivers its completion on the main thread (documented)
//   but the closure is not @MainActor-isolated by the type system. Wrapping in
//   Task { @MainActor } provides compiler-enforced actor isolation for all
//   state mutations that follow, including panel.orderOut, gate clears, and
//   the completion callback.
//
// WHY DEFERRED GATE CLEAR (DispatchQueue.main.async INSIDE Task { @MainActor }):
//   The global mouse-down monitor fires on the same runloop turn that dismisses
//   the panel. Clearing hasActiveOverlay synchronously — or even at the next
//   actor turn — lets the monitor see false on that delivery and call
//   performClose. One DispatchQueue.main.async hop defers the clear past the
//   monitor's event delivery. The two hops serve different purposes: the Task
//   hop enforces actor isolation; the GCD hop defers the gate clear past AppKit
//   event delivery.
//
// WHY completion IS CALLED OUTSIDE THE GCD HOP:
//   The GCD hop's sole responsibility is deferring the gate flag clears past
//   the event monitor's run-loop turn. completion is declared @MainActor and
//   must be called with compiler-enforced actor isolation — which the GCD
//   closure does not provide (main thread at runtime, but not statically
//   verified). completion is therefore called in the Task { @MainActor } scope
//   after the GCD hop has been *queued* (guaranteeing the gate clears are
//   deferred) but before it has *executed*. This means completion fires with
//   the gate flags still true on the current run-loop turn — which is correct:
//   the popover should not close on the same turn as completion. The gate
//   clears on the next turn via the GCD hop, allowing normal popover-close
//   behaviour to resume.
//
// NOTE ON CALLING mbkOpenFilePicker FROM WITHIN completion:
//   NSOpenPanel is modal — it blocks all user interaction until dismissed.
//   A second mbkOpenFilePicker call cannot be triggered by the user while a
//   picker is open, so calling it from within completion is not a practical
//   concern. The gateWasAlreadyArmed snapshot exists to handle a sheet being
//   open concurrently (a legitimate case), not to guard against two pickers
//   coexisting (which macOS prevents at the AppKit level).

import AppKit

/// Presents a directory-selection `NSOpenPanel` anchored above the popover,
/// with automatic overlay-gate management.
///
/// The panel floats one window level above the popover's `nonactivatingPanel`
/// window so it is always visible. Key focus is transferred via
/// `makeKeyAndOrderFront` after the panel is shown (level alone does not
/// transfer key focus on macOS 14+).
///
/// The overlay gate is armed for the full lifetime of the panel and cleared on
/// the next run-loop turn after the panel is dismissed, preventing a spurious
/// outside-click dismiss. See the file header for full design rationale.
///
/// - Note: Unlike `.mbkSheet` and `.mbkAlert`, this function requires an
///   explicit `overlayGate:` parameter. It is a free function with no SwiftUI
///   view hierarchy context, so it cannot resolve `MBKOverlayGate` from
///   `@Environment`. Pass the same gate instance you injected via
///   `.environment(overlayGate)` at your root view.
///
/// - Parameters:
///   - overlayGate: The gate owned by the enclosing `MBKPanelController`.
///   - message: Optional message shown inside the panel above the file list.
///   - completion: Called on the `@MainActor` with the chosen `URL`, or `nil`
///     if the user cancelled. Called on the same run-loop turn as panel dismissal,
///     before the gate is cleared — safe to present follow-up UI immediately.
@MainActor
public func mbkOpenFilePicker(
    overlayGate: MBKOverlayGate,
    message: String? = nil,
    completion: @escaping @MainActor (URL?) -> Void
) {
    mbkLog("FilePicker", "mbkOpenFilePicker called — overlayGate.hasActiveOverlay=\(overlayGate.hasActiveOverlay) hasFilePickerOverlay=\(overlayGate.hasFilePickerOverlay)")
    mbkLog("FilePicker", "window count=\(NSApp.windows.count)")
    for w in NSApp.windows {
        let title = w.title.isEmpty ? "<empty>" : w.title
        mbkLog("FilePicker", "  window #\(w.windowNumber) styleMask=\(w.styleMask.rawValue) isKey=\(w.isKeyWindow) title=\(title)")
    }

    let gateWasAlreadyArmed = overlayGate.hasActiveOverlay
    mbkLog("FilePicker", "gateWasAlreadyArmed=\(gateWasAlreadyArmed)")

    let popoverWindow = NSApp.windows.first {
        $0.styleMask.contains(.nonactivatingPanel)
    }
    let popoverLevel = popoverWindow?.level ?? .floating
    mbkLog("FilePicker", "popoverWindow=#\(popoverWindow?.windowNumber ?? -1) level=\(popoverLevel.rawValue)")

    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = "Select"
    if let message { panel.message = message }
    panel.level = NSWindow.Level(rawValue: popoverLevel.rawValue + 1)
    mbkLog("FilePicker", "panel created — level=\(panel.level.rawValue)")

    overlayGate.hasActiveOverlay = true
    overlayGate.hasFilePickerOverlay = true
    mbkLog("FilePicker", "hasActiveOverlay=true hasFilePickerOverlay=true — calling panel.begin")

    panel.begin { response in
        Task { @MainActor in
            mbkLog("FilePicker", "panel.begin completion — response=\(response.rawValue) gateWasAlreadyArmed=\(gateWasAlreadyArmed)")
            panel.orderOut(nil)
            mbkLog("FilePicker", "panel.orderOut called — window count now=\(NSApp.windows.count)")
            // Queue the gate clear on the next run-loop turn so the event monitor
            // (which fires on the same turn as panel dismissal) still sees the gate
            // armed and does not call performClose prematurely.
            // See file header “WHY DEFERRED GATE CLEAR” for full rationale.
            DispatchQueue.main.async {
                overlayGate.hasFilePickerOverlay = false
                mbkLog("FilePicker", "hasFilePickerOverlay=false")
                if gateWasAlreadyArmed {
                    mbkLog("FilePicker", "gate was already armed by concurrent overlay — preserving hasActiveOverlay=true")
                } else {
                    overlayGate.hasActiveOverlay = false
                    mbkLog("FilePicker", "hasActiveOverlay=false")
                }
            }
            // completion is called here — in the @MainActor Task scope, after the
            // GCD hop is queued but before it executes. This restores full
            // compiler-enforced actor isolation for the callback.
            // See file header “WHY completion IS CALLED OUTSIDE THE GCD HOP”.
            let url = response == .OK ? panel.url : nil
            mbkLog("FilePicker", "calling completion url=\(String(describing: url))")
            completion(url)
            mbkLog("FilePicker", "completion done")
        }
    }

    // panel.begin synchronously places the panel on screen (the completion block
    // fires only when the user dismisses it, not at begin-return time). The panel
    // therefore has a valid window number and is already visible here. However
    // the nonactivatingPanel popover retains key status — makeKeyAndOrderFront
    // transfers key focus to the picker so the user sees it immediately.
    // See file header “WHY panel.makeKeyAndOrderFront” for full rationale.
    panel.makeKeyAndOrderFront(nil)
    mbkLog("FilePicker", "panel.begin returned — panel=#\(panel.windowNumber) level=\(panel.level.rawValue)")
}
