// OverlayGate.swift
// MenuBarKit
//
// MBKOverlayGate is the single source of truth for whether any overlay
// (SwiftUI sheet, NSOpenPanel, alert) is currently active on top of the popover.
//
// It is @Observable so SwiftUI views can read it, and @MainActor because
// all overlay state must mutate on the main thread.
//
// USAGE:
//   1. Create one MBKOverlayGate per popover.
//   2. Pass it to MBKPopoverController, MBKAnchoredSheet, MBKFilePicker, and mbkAlert.
//   3. The host app does not need to touch hasActiveOverlay directly —
//      MBKAnchoredSheet, mbkOpenFilePicker, and mbkAlert manage it automatically.
//
// WHY A SEPARATE OBJECT (not a Bool on the host's AppState):
//   The gate is MenuBarKit's concern, not the host app's.
//
// WHY A SINGLE BOOL (not a reference-counted integer):
//   In normal usage only one overlay (sheet OR file picker) can be live at a
//   time. The one exception is an alert presented while a sheet is open —
//   see Alert.swift for how MBKAlertModifier handles that case safely.
//   If a future use-case genuinely requires concurrent overlays beyond this,
//   replace the Bool with an Int and use increment/decrement.
//
// WHY hasActiveOverlay IS public internal(set) var:
//   All write sites live inside the MenuBarKit module. internal(set) scopes
//   the setter to the module — host apps get a read-only public view.
//   NOTE: private(set) would be wrong here — it scopes the setter to the
//   declaring type only, making write sites in AnchoredSheet.swift,
//   FilePicker.swift, and Alert.swift compile errors.

import Foundation
import Observation

/// Tracks whether any overlay (sheet, file picker, or alert) is currently live over the popover.
/// Managed automatically by `MBKAnchoredSheet`, `mbkOpenFilePicker`, and `mbkAlert`;
/// read by `MBKPopoverController.popoverShouldClose` to block dismiss.
///
/// ❌ Host apps must not write `hasActiveOverlay` or `hasFilePickerOverlay` directly.
/// Use `.mbkSheet`, `mbkOpenFilePicker`, and `.mbkAlert` instead.
@Observable
@MainActor
public final class MBKOverlayGate {
    /// `true` while any sheet, file picker, or alert is live over the popover.
    /// Managed automatically by `MBKAnchoredSheet`, `mbkOpenFilePicker`, and `MBKAlertModifier`.
    /// Read by `MBKPopoverController.popoverShouldClose`.
    /// Setter is `internal(set)` — only MenuBarKit write sites may mutate this.
    public internal(set) var hasActiveOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasActiveOverlay: \(oldValue) → \(self.hasActiveOverlay)")
        }
    }

    /// `true` specifically when a file picker panel is open.
    /// Used by `MBKPopoverController`'s event monitor to distinguish an outside
    /// click aimed at the picker from a genuine dismiss gesture, even when a
    /// sheet child window is simultaneously present.
    /// Setter is `internal(set)` — only `mbkOpenFilePicker` may mutate this.
    public internal(set) var hasFilePickerOverlay: Bool = false {
        didSet {
            mbkLog("OverlayGate", "hasFilePickerOverlay: \(oldValue) → \(self.hasFilePickerOverlay)")
        }
    }

    /// Creates a new gate with all overlays inactive.
    ///
    /// No `mbkLog` here — `init` fires before the host can install a custom
    /// `mbkLogHandler`. Both flags start `false`; the `didSet` observers capture
    /// every subsequent state change.
    public init() {}
}
