// AppState.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Minimal state for 3 spike scenarios:
//   1. State persists across popover hide/show
//   2. Sheet anchors to popover + blocks outside-click dismiss
//   3. File picker works from popover and from inside sheet

import Foundation

enum NavSheetRoute: Equatable {
    case main
    case settings
}

@Observable
@MainActor
final class NavSheetAppState {
    var route: NavSheetRoute = .main
    var counter: Int = 0
    var showSheet: Bool = false
    var pickedPath: String = ""
    var sheetPickedPath: String = ""
}
