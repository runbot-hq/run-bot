// AppState.swift
// RunBotSpike
//
// App-specific state only. No popover lifecycle, no overlay gate —
// those live in MenuBarKit.
//
//   route           — which top-level view is visible.
//   pickedPath      — result from file picker opened in SettingsView.
//   sheetPickedPath — result from file picker opened inside SheetView.
//   showSheetAlert  — drives the .alert modifier in SheetView.

import Foundation
import Observation

/// Navigation destinations for the spike's root view switcher.
enum Route: Equatable {
    /// The main landing view.
    case main
    /// The settings view that exercises sheet and file picker scenarios.
    case settings
}

/// Spike-specific app state. Owns only navigation and file-picker results.
@Observable
@MainActor
final class AppState {
    /// Currently displayed route.
    var route: Route = .main
    /// Path selected by the file picker opened from SettingsView (popover context).
    var pickedPath: String = ""
    /// Path selected by the file picker opened from SheetView (sheet context).
    var sheetPickedPath: String = ""
    /// Controls the error alert presented from inside SheetView.
    var showSheetAlert: Bool = false
}
