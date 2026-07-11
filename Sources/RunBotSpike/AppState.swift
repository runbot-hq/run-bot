// AppState.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Single source of truth for the spike. Deliberately minimal — only what
// crosses view boundaries:
//
//   route         — which top-level view is visible in the popover.
//   pickedPath    — result from file picker opened in SettingsView (displayed
//                   in SettingsView after dismissal).
//   sheetPickedPath — result from file picker opened inside SheetView.
//   hasActiveOverlay — true while any sheet or file picker is open on top of
//                   the popover. Read by popoverShouldClose in AppDelegate to
//                   block dismiss. Set/cleared by anchoredSheet modifier and
//                   openFilePicker; never set by individual views directly.
//
// WHAT DOES NOT LIVE HERE:
//   Sheet presentation booleans (e.g. showSheet) — these are local @State in
//   the view that owns the sheet. Storing them here would mean every new sheet
//   in any view requires an AppState change, which is the wrong coupling.
//   The anchoredSheet modifier bridges local @State to hasActiveOverlay
//   automatically so views never need to touch AppState for sheet lifecycle.
//
// @Observable (Observation framework, macOS 14+) — views re-render only when
// a property they actually read changes. No @Published boilerplate needed.
// @MainActor — all mutations on main thread, required for UI state.

import Foundation

enum NavSheetRoute: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class NavSheetAppState {
    var route: NavSheetRoute = .main
    var hasActiveOverlay: Bool = false  // dismiss gate — managed by anchoredSheet + openFilePicker
    var pickedPath: String = ""         // result from file picker in SettingsView
    var sheetPickedPath: String = ""    // result from file picker in SheetView
}
