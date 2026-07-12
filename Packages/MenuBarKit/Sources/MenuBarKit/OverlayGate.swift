// OverlayGate.swift
// MenuBarKit
//
// MBKOverlayGate is the single source of truth for whether any overlay
// (SwiftUI sheet, NSOpenPanel) is currently active on top of the popover.
//
// It is @Observable so SwiftUI views can read it, and @MainActor because
// all overlay state must mutate on the main thread.
//
// USAGE:
//   1. Create one MBKOverlayGate per popover.
//   2. Pass it to MBKPopoverController, MBKAnchoredSheet, and MBKFilePicker.
//   3. The host app does not need to touch hasActiveOverlay directly —
//      MBKAnchoredSheet and mbkOpenFilePicker manage it automatically.
//
// WHY A SEPARATE OBJECT (not a Bool on the host's AppState):
//   The gate is MenuBarKit's concern, not the host app's. The host app should
//   not need to know about it at all — MBKAnchoredSheet and MBKFilePicker
//   manage it automatically. The host's AppState can observe it if needed,
//   but does not own it.
//
// WHY A SINGLE BOOL (not a reference-counted integer):
//   In normal usage only one overlay (sheet OR file picker) can be live at a
//   time over the popover — a sheet blocks navigation and a file picker
//   attaches to the same window, so they cannot both be open simultaneously
//   through the supported API surface. A single bool is therefore sufficient.
//
//   The one exception is an alert presented while a sheet is open: alerts are
//   system modals that AppKit manages independently of the gate. The alert
//   path (mbkAlert, #2038) must be implemented carefully to avoid clobbering
//   the sheet gate. Until #2038 is resolved, do not set hasActiveOverlay
//   directly from host-app views while a sheet may be concurrently open
//   (see SPIKE ONLY comment in SettingsView.swift).
//
//   If a future use-case genuinely requires concurrent overlays, replace the
//   Bool with an Int and use increment/decrement rather than set/clear.
//
// WHY hasActiveOverlay IS public var (not private(set)):
//   MBKAnchoredSheet and mbkOpenFilePicker write it directly to manage the
//   gate lifetime. The planned mbkAlert modifier (#2038) will also write it.
//   It is public var by necessity of the gate-ownership contract, not by
//   accident. Host apps must not write it directly (see SPIKE ONLY comment
//   in SettingsView.swift and issue #2038).

import Foundation
import Observation

/// Tracks whether any overlay (sheet or file picker) is currently live over the popover.
/// Managed automatically by `MBKAnchoredSheet` and `mbkOpenFilePicker`;
/// read by `MBKPopoverController.popoverShouldClose` to block dismiss.
///
/// ❌ Host apps must not write `hasActiveOverlay` directly. Use `mbkSheet`,
/// `mbkOpenFilePicker`, and (once available) `mbkAlert` — they manage the
/// gate lifetime internally. Direct mutation is a spike-only shortcut
/// that does not compose safely with concurrent overlays (see issue #2038).
@Observable
@MainActor
public final class MBKOverlayGate {
    /// `true` while any sheet or file picker is live over the popover.
    /// Managed automatically by MBKAnchoredSheet and MBKFilePicker.
    /// Read by MBKPopoverController.popoverShouldClose.
    public var hasActiveOverlay: Bool = false

    /// Creates a new gate with no active overlay.
    public init() {}
}
