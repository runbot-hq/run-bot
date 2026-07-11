// AppState.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Minimal state for 3 spike scenarios:
//   1. Sheet anchors to popover + blocks outside-click dismiss
//   2. File picker works from popover and from inside sheet

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
    var pickedPath: String = ""
    var sheetPickedPath: String = ""
}
