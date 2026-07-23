// AppDelegate+Navigation.swift
// RunBot
import AppKit
import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Navigation
//
// This file is the SINGLE SOURCE OF TRUTH for:
//   1. ALL view factories (mainView, settingsView, etc.)
//   2. ALL navigation calls (navigateToSettings, navigateBack, etc.)
//   3. NavState / validatedView(for:)
//
// ARCHITECTURE RULES:
// ❌ NEVER inline view construction in AppDelegate.swift.
// ❌ NEVER add a second navigation method elsewhere.
// ❌ NEVER call navigate(to:) from a SwiftUI view — use callbacks only.
// ❌ NEVER wrap StepLogView in PanelContainerView here.
//    PanelContainerView is applied per view that needs sheets/dim overlay.
//    Nesting it causes multiple overlapping dim overlays → gray/black flash.
//
// SIZE REPORTING:
// View factories no longer pass onSizeChange to PanelContainerView.
// Sizing is driven by NavigationShellView's permanent GeometryReader, which
// wraps whatever is in the content slot — including the entire PanelContainerView
// tree. PanelContainerView.onSizeChange is retained as a no-op default for
// call-site compatibility but is NOT the active size-reporting path.
// See NavigationShell.swift for the full sizing architecture.

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - View factories

    /// Builds the main panel view wrapped in PanelContainerView (dim overlay + sheet detection).
    ///
    /// ❌ Do NOT pass onSizeChange here — NavigationShellView owns sizing.
    func mainView() -> AnyView {
        let inner = PanelMainView(
            onStepTap: { [weak self] (job: ActiveJob, step: GitHubStep) in
                guard let self else { return }
                self.appState.savedNavState = .stepLog(job: job, step: step)
                self.navigate(to: self.wrapEnv(StepLogView(
                    job: job,
                    step: step,
                    onBack: { [weak self] in
                        self?.appState.savedNavState = nil
                        self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                    }
                )))
            },
            onSelectSettings: { [weak self] in self?.navigateToSettings() }
        )
        return wrapEnv(PanelContainerView(content: inner))
    }

    /// Builds the settings view wrapped in PanelContainerView (sheets are launched from here).
    ///
    /// ❌ Do NOT pass onSizeChange here — NavigationShellView owns sizing.
    /// ❌ NEVER wrap StepLogView in PanelContainerView — StepLogView has no sheets.
    func settingsView() -> AnyView {
        let inner = SettingsView(
            onBack: { [weak self] in
                self?.appState.savedNavState = nil
                self?.panelSheetState.clearRunnerSheet()
                self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
            },
            appState: appState
        )
        return wrapEnv(PanelContainerView(content: inner))
    }

    // MARK: - Navigation actions

    func navigateToSettings() {
        appState.savedNavState = .settings
        navigate(to: settingsView())
        makeKeyForTextInput()
    }

    // MARK: - NavState restoration

    func validatedView(for state: NavState) -> AnyView? {
        switch state {
        case .main:
            return nil
        case .settings:
            return settingsView()
        case .stepLog(let job, let step):
            guard appState.runnerState.jobs.contains(where: { $0.id == job.id }) else { return nil }
            return wrapEnv(StepLogView(
                job: job,
                step: step,
                onBack: { [weak self] in
                    self?.appState.savedNavState = nil
                    self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                }
            ))
        }
    }
}
