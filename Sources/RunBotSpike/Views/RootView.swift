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
//
// WHY .environment(appState) ON EACH BRANCH:
//   appState is already injected at the NSHostingController root in
//   AppDelegate.setupPopover(), so SwiftUI would propagate it automatically.
//   The explicit re-injection here is redundant and should NOT be copied into
//   the main app — it creates ambiguity about where the authoritative injection
//   point is. It is kept in the spike only because the spike was written
//   before that root injection was confirmed to propagate correctly through
//   enum-switched branches. Verified: it does. Remove in the migration PR.

import SwiftUI

struct NavSheetRootView: View {
    @Environment(NavSheetAppState.self) private var appState

    var body: some View {
        switch appState.route {
        case .main:     NavSheetMainView().environment(appState)     // redundant — see header
        case .settings: NavSheetSettingsView().environment(appState) // redundant — see header
        }
    }
}
