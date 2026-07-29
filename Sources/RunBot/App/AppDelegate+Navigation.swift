// AppDelegate+Navigation.swift
// RunBot
import AppKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Navigation
//
// Navigation is now fully owned by RootPanelView via appState.savedNavState.
// All route changes are pure state mutations — no setRootView(), no AnyView
// factory methods, no validatedView(for:).
//
// This file retains only the AppKit-wiring callbacks that RootPanelView cannot
// call directly:
//   • navigateToSettings() — mutates savedNavState + promotes app to key
//   • navigateBack()       — clears savedNavState + clears runner sheet
//
// ARCHITECTURE RULES:
// ❌ NEVER inline view construction in AppDelegate.swift.
// ❌ NEVER add a second navigation method elsewhere.
// ❌ NEVER call navigate(to:) from a SwiftUI view — use callbacks only.
// ❌ NEVER wrap any view in PanelContainerView here.
//    PanelContainerView is applied per-branch inside RootPanelView.
//    Nesting it causes multiple overlapping dim overlays → gray/black flash.

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - Navigation actions

    /// Navigates to the settings view.
    /// Mutates savedNavState — RootPanelView reacts and switches to the settings branch.
    /// Also promotes the app to key so TextFields in Settings receive input.
    func navigateToSettings() {
        appState.savedNavState = .settings
        NSApp.activate()
    }

    /// Navigates back to main.
    /// Clears savedNavState — RootPanelView routes to the .main branch.
    /// Also clears any active runner sheet so it does not ghost on re-open.
    func navigateBack() {
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
    }
}
