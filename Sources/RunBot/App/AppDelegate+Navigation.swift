// AppDelegate+Navigation.swift
// RunBot
import AppKit
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
// ❌ NEVER wrap StepLogView or SettingsView in PanelContainerView here.
//    PanelContainerView is applied ONCE at the root in mainView() only.
//    Nesting it causes multiple overlapping dim overlays → gray/black flash.

/// Extension adding navigation functionality to AppDelegate.
extension AppDelegate {

    // MARK: - View factories

    /// Builds the root SwiftUI view. PanelContainerView is applied HERE and ONLY here.
    /// When `navigate(to:)` swaps `rootView` to settings or step-log, those views are
    /// placed directly — the PanelContainerView shell is NOT re-applied.
    /// Note: `settingsView()` applies its own PanelContainerView (sheets require it),
    ///    but that is `settingsView()`'s responsibility — not this function's.
    /// ❌ NEVER re-wrap those views from here —
    ///    nesting causes multiple overlapping dim overlays → gray/black flash.
    func mainView() -> AnyView {
        let inner = PanelMainView(
            onStepTap: { [weak self] job, step in
                guard let self else { return }
                self.savedNavState = .stepLog(job: job, step: step)
                self.navigate(to: self.wrapEnv(StepLogView(
                    job: job,
                    step: step,
                    onBack: { [weak self] in
                        self?.savedNavState = nil
                        self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                    }
                )))
            },
            onSelectSettings: { [weak self] in self?.navigateToSettings() }
        )
        // PanelContainerView applied once at root.
        return wrapEnv(PanelContainerView(content: inner))
    }

    /// Builds the settings view, wrapped in PanelContainerView because sheets are
    /// launched from SettingsView and the dim overlay is required.
    /// ❌ NEVER wrap StepLogView in PanelContainerView — StepLogView has no sheets;
    ///    a double-wrap here causes the gray/black flash regression.
    ///
    /// No `onRestartPolling` is passed — ScopeStore mutations are observed by
    /// `RunnerPoller.startObservingScopes` via `withObservationTracking`, which
    /// restarts the poll task automatically without an explicit callback.
    func settingsView() -> AnyView {
        let inner = SettingsView(
            onBack: { [weak self] in
                self?.savedNavState = nil
                self?.panelSheetState.clearRunnerSheet()
                self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
            },
            oauthService: oauthService,
            lifecycleService: lifecycleService,
            runnerState: runnerState,
            autoUpdater: autoUpdater
        )
        // PanelContainerView needed here too: sheets are presented from SettingsView.
        return wrapEnv(PanelContainerView(content: inner))
    }

    // MARK: - Navigation actions

    /// Navigates to the settings view and promotes to key for text input.
    func navigateToSettings() {
        savedNavState = .settings
        navigate(to: settingsView())
        makeKeyForTextInput()
    }

    // MARK: - NavState restoration

    /// Returns the correct view for a saved nav state, or nil if stale.
    func validatedView(for state: NavState) -> AnyView? {
        switch state {
        case .main:
            // Already at main — no navigation needed.
            return nil
        case .settings:
            return settingsView()
        case .stepLog(let job, let step):
            // TODO(#1099): This guard checks the live snapshot in runnerState which is
            // empty until the first poll (~2–5 s after launch). A user who reopens the app
            // quickly after viewing a step log will always fail this guard and land on main.
            // Preferred fix: let StepLogView render a loading/empty state and remove this guard.
            // Alternative: persist the last-seen job ID and validate against that.
            //
            // `runnerState.jobs` holds the last snapshot pushed by `RunnerPoller`
            // via `applyFetchResult → MainActor.run`. It is `@MainActor`-isolated and
            // can be read synchronously here.
            guard runnerState.jobs.contains(where: { $0.id == job.id }) else { return nil }
            // No PanelContainerView here — StepLogView has no sheets.
            return wrapEnv(StepLogView(
                job: job,
                step: step,
                onBack: { [weak self] in
                    self?.savedNavState = nil
                    self?.navigate(to: self?.mainView() ?? AnyView(EmptyView()))
                }
            ))
        }
    }
}
