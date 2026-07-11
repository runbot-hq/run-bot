// Views/RootView.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Minimal nav host. Switches between Main and Settings based on appState.route.
//
// WHY NOT NavigationStack:
//   NavigationStack wraps content in a scroll view internally, which adds
//   unwanted chrome and geometry side effects inside a fixed-size popover.
//   A plain switch over an enum keeps the popover size clean and makes
//   transitions explicit — no implicit push/pop animation surprises.
//
// WHY NOT NavigationSplitView:
//   Designed for multi-column layouts. Overkill and visually wrong inside
//   a narrow popover.
//
// WHY enum-based route instead of a Bool:
//   A Bool (isShowingSettings) only works for two screens. An enum scales
//   to N screens without adding more state properties, and makes exhaustive
//   switch handling compiler-enforced.

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
