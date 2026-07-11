// Views/RootView.swift
// RunBotSpike - spike/swiftui-nav-sheet

import SwiftUI

struct NavSheetRootView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        switch appState.route {
        case .main:     NavSheetMainView().environment(appState)
        case .settings: NavSheetSettingsView().environment(appState)
        }
    }
}
