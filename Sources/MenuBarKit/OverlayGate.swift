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
//   3. Pass { gate.hasActiveOverlay } as the PopoverController's closure.
//
// WHY A SEPARATE OBJECT (not a Bool on the host's AppState):
//   The gate is MenuBarKit's concern, not the host app's. The host app should
//   not need to know about it at all — MBKAnchoredSheet and MBKFilePicker
//   manage it automatically. The host's AppState can observe it if needed,
//   but does not own it.

import Foundation
import Observation

@Observable
@MainActor
public final class MBKOverlayGate {
    /// True while any sheet or file picker is live over the popover.
    /// Managed automatically by MBKAnchoredSheet and MBKFilePicker.
    /// Read by MBKPopoverController.popoverShouldClose.
    public var hasActiveOverlay: Bool = false

    public init() {}
}
