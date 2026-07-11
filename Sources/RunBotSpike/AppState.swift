// AppState.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Single source of truth for the spike. Kept deliberately minimal — only what
// is needed to drive the two scenarios being tested:
//
//   Scenario 1 — Sheet anchors + blocks dismiss:
//     showSheet drives .anchoredSheet() in SettingsView.
//
//   Scenario 2 — File picker from popover and from inside sheet:
//     pickedPath / sheetPickedPath store the result so the UI can confirm
//     the picker actually ran and returned a value.
//
// @Observable (Observation framework, iOS 17 / macOS 14+) means SwiftUI views
// only re-render when a property they actually read changes — no @Published
// boilerplate, no ObservableObject conformance needed.
//
// @MainActor ensures all mutations happen on the main thread, which is required
// for driving UI updates safely.

import Foundation

enum NavSheetRoute: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class NavSheetAppState {
    var route: NavSheetRoute = .main
    var showSheet: Bool = false
    var pickedPath: String = ""       // set by file picker opened from SettingsView
    var sheetPickedPath: String = ""  // set by file picker opened from SheetView
}
