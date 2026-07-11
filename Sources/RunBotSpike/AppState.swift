// AppState.swift
// RunBotSpike
//
// App-specific state only. No popover lifecycle, no overlay gate —
// those live in MenuBarKit.
//
//   route           — which top-level view is visible.
//   pickedPath      — result from file picker opened in SettingsView.
//   sheetPickedPath — result from file picker opened inside SheetView.

import Foundation
import Observation

enum Route: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class AppState {
    var route: Route = .main
    var pickedPath: String = ""
    var sheetPickedPath: String = ""
}
