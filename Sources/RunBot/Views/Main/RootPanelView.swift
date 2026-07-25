// RootPanelView.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// MARK: - RootPanelView
//
// ARCHITECTURE:
// This is the single persistent root view passed to MBKPopoverController.
// It owns ALL route switching for the panel via a `Group { switch } .id(route)`
// pattern copied directly from the MBK example's RootView.swift.
//
// WHY .id(route):
// MBKPopoverController wraps its root view in a GeometryReader inside `wrapped()`.
// That GeometryReader's `onAppear` and `onChange(of: geo.size)` are the ONLY
// mechanism by which MBK learns the correct panel size. If SwiftUI considers
// a new route structurally identical to the previous one (e.g. main → main)
// it will NOT remount — onAppear is skipped and the size is never re-reported.
// `.id(route)` forces SwiftUI to tear down and remount the routed subtree on
// every route change, guaranteeing the GeometryReader always fires fresh.
//
// WHY NOT setRootView():
// The old pattern called `popoverController?.setRootView(mainView())` on every
// navigation. That swaps AnyView blobs which (a) can silently skip onAppear
// and (b) requires AppDelegate to hold factory methods for every view. Routing
// via state mutation here removes that responsibility.
//
// PanelContainerView is applied INSIDE each branch, not here at the root, to
// preserve the per-branch dimming contract (Settings and main both need it;
// StepLogView must NOT get it — see AppDelegate+Navigation.swift comment).
//
// ❌ NEVER nest RootPanelView inside another PanelContainerView.
// ❌ NEVER add .frame(maxWidth: .infinity, maxHeight: .infinity) here.
// ❌ NEVER remove the .id(navState) modifier.

struct RootPanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(PanelVisibilityState.self) private var panelVisibilityState

    /// Callbacks from AppDelegate used for actions that still require AppKit wiring.
    let onSelectSettings: () -> Void
    let onBack: () -> Void
    let onStepBack: () -> Void

    var body: some View {
        // .id(navState) is load-bearing — see ARCHITECTURE comment above.
        // Changing or removing it will break MBK's GeometryReader remount.
        Group {
            switch appState.savedNavState {
            case .none, .main:
                mainBranch
            case .settings:
                settingsBranch
            case .stepLog(let job, let step):
                stepLogBranch(job: job, step: step)
            }
        }
        .id(navState)
    }

    // MARK: - Route branches

    /// The main panel — runners + actions list.
    /// PanelContainerView is applied here (owns the dim overlay for sheets).
    @ViewBuilder private var mainBranch: some View {
        PanelContainerView(
            content: PanelMainView(
                onStepTap: { job, step in
                    appState.savedNavState = .stepLog(job: job, step: step)
                },
                onSelectSettings: onSelectSettings
            )
        )
    }

    /// The settings view.
    /// PanelContainerView applied here too — settings presents sheets.
    @ViewBuilder private var settingsBranch: some View {
        PanelContainerView(
            content: SettingsView(
                onBack: onBack,
                appState: appState
            )
        )
    }

    /// The step log view for a specific job + step.
    /// ❌ NO PanelContainerView — StepLogView has no sheets and a double-wrap
    ///    causes the gray/black flash regression.
    @ViewBuilder private func stepLogBranch(job: ActiveJob, step: GitHubStep) -> some View {
        StepLogView(
            job: job,
            step: step,
            onBack: onStepBack
        )
    }

    // MARK: - Route identity key

    /// A stable string key derived from the current nav state, used as the `.id()`
    /// value to force SwiftUI to remount the routed subtree on every route change.
    private var navState: String {
        switch appState.savedNavState {
        case .none, .main:                      return "main"
        case .settings:                         return "settings"
        case .stepLog(let job, let step):       return "stepLog-\(job.id)-\(step.number)"
        }
    }
}
