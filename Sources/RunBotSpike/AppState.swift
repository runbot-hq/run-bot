// AppState.swift
// RunBotSpike - spike/swiftui-nav-sheet

import Foundation

// MARK: - Route

enum NavSheetRoute: Equatable {
    case main
    case settings
}

// MARK: - App state

@Observable
@MainActor
final class NavSheetAppState {
    var route: NavSheetRoute = .main
    var counter: Int = 0
    var text: String = ""
    var settingsCounter: Int = 0
    var settingsToggle: Bool = false
    var showSettingsSheet: Bool = false
    var sheetCounter: Int = 0
    var sheetText: String = ""
    var taskFireCount: Int = 0
    var pickedFolderPath: String = ""
    var sheetPickedFolderPath: String = ""
    var showSheetAlert: Bool = false
    var overlayCount: Int = 0 {
        didSet { log("State", "overlayCount \(oldValue) -> \(overlayCount)") }
    }
}
