// AppDelegate+Navigation.swift
// RunBot
import AppKit
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Navigation
//
// This file is the SINGLE SOURCE OF TRUTH for:
//   1. ALL view factories (mainView, settingsView, etc.) — KEPT for backward
//      compat while the full step-5 removal is pending, but no longer used as
//      the primary nav mechanism. RootPanelView owns routing now.
//   2. Navigation callbacks wired into RootPanelView.
//   3. NavState / validatedView(for:) — kept for onWillShow restoration.
//
// ARCHITECTURE RULES:
// ❌ NEVER inline view construction in AppDelegate.swift.
// ❌ NEVER add a second navigation method elsewhere.
// ❌ NEVER call navigate(to:) from a SwiftUI view — use callbacks only.
// ❌ NEVER wrap StepLogView or SettingsView in PanelContainerView here.
//    PanelContainerView is applied ONCE per branch inside RootPanelView.
//    Nesting it causes multiple overlapping dim overlays → gray/black flash.

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - View factories
    // These are kept for validatedView(for:) and legacy call sites.
    // Primary routing is now owned by RootPanelView via appState.savedNavState.

    /// Builds the root SwiftUI view. PanelContainerView is applied HERE and ONLY here.
    /// Used by validatedView(for:) and legacy fallback paths.
    func mainView() -> AnyView {
        let inner = PanelMainView(
            onStepTap: { [weak self] (job: ActiveJob, step: GitHubStep) in
                guard let self else { return }
                self.appState.savedNavState = .stepLog(job: job, step: step)
            },
            onSelectSettings: { [weak self] in self?.navigateToSettings() }
        )
        return wrapEnv(PanelContainerView(content: inner))
    }

    /// Builds the settings view.
    /// Used by validatedView(for:) and legacy fallback paths.
    func settingsView() -> AnyView {
        let inner = SettingsView(
            onBack: { [weak self] in
                self?.navigateBack()
            },
            appState: appState
        )
        return wrapEnv(PanelContainerView(content: inner))
    }

    // MARK: - Navigation actions

    /// Navigates to the settings view.
    /// Primary path: mutates savedNavState — RootPanelView reacts.
    /// Also promotes to key for text input.
    func navigateToSettings() {
        appState.savedNavState = .settings
        makeKeyForTextInput()
    }

    /// Navigates back to main.
    /// Clears savedNavState — RootPanelView routes to .main branch.
    func navigateBack() {
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
    }

    // MARK: - NavState restoration

    /// Returns the correct view for a saved nav state, or nil if stale.
    /// Used by onWillShow for state restoration only — NOT for primary routing.
    func validatedView(for state: NavState) -> AnyView? {
        switch state {
        case .main:
            return nil
        case .settings:
            return settingsView()
        case .stepLog(let job, let step):
            // TODO(#1099): This guard checks the live snapshot in runnerState which is
            // empty until the first poll (~2–5 s after launch). A user who reopens the app
            // quickly after viewing a step log will always fail this guard and land on main.
            guard appState.runnerState.jobs.contains(where: { $0.id == job.id }) else { return nil }
            return wrapEnv(StepLogView(
                job: job,
                step: step,
                onBack: { [weak self] in
                    self?.navigateBack()
                }
            ))
        }
    }
}
