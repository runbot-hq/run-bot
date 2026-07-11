// Views/RootView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Minimal nav host. Switches between Main and Settings based on appState.route.
//
// WHY NOT NavigationStack:
//   NavigationStack uses a scroll view internally which adds unwanted chrome
//   and geometry inside a popover. A plain switch over an enum keeps the
//   popover size clean and transition behaviour explicit.

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
