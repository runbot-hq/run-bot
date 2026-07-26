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

/// Single persistent root view passed to `MBKPopoverController`.
/// Owns all panel route switching via `Group { switch }.id(navState)`.
struct RootPanelView: View {
    /// Core runner/job/action/rate-limit state, injected via `wrapEnv`.
    @Environment(AppState.self) private var appState

    /// Pass-through environment injection for PanelContainerView.
    ///
    /// RootPanelView does not read panelVisibilityState directly, but it MUST
    /// declare this property so the value is present in the environment subtree.
    /// PanelContainerView (rendered inside mainBranch and settingsBranch) reads
    /// it via its own @Environment lookup to drive the dim overlay.
    /// ❌ NEVER remove this property.
    /// ❌ NEVER remove PanelVisibilityState from wrapEnv() in AppDelegate.
    @Environment(PanelVisibilityState.self) private var panelVisibilityState

    /// Called when the user taps the settings gear. Requires AppKit wiring (key promotion).
    let onSelectSettings: () -> Void
    /// Called when the user taps Back from the settings route.
    let onBack: () -> Void
    /// Called when the user taps Back from the step-log route.
    let onStepBack: () -> Void

    /// Switches between route branches; `.id(navState)` forces remount on every change.
    var body: some View {
        // ⚠️ LOGGING POLICY: This render log fires on every recompose, not just route
        // transitions. It is intentionally kept until MBK sizing behaviour is confirmed
        // stable — we need full recompose visibility to diagnose spurious re-renders and
        // GeometryReader interaction during the fix/arrow-center-drift testing window.
        // onChange(of: navState) below covers route transitions only; this line covers
        // everything. Do NOT remove until #2265 is resolved and route-switching under
        // MBKPopoverController has been verified in production builds.
        #if DEBUG
        log("【RootPanelView.body】rendered navState=\(navState)", category: .panel)
        #endif
        return Group {
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
        // ⚠️ Temporary — remove after side-jump bug (#2265) is resolved.
        // Logs every nav-state transition for MBK sizing diagnostics.
        // category: .panel is already #if DEBUG gated at the call site above;
        // this onChange is intentionally ungated so the transition itself is
        // always visible in debug logs during the investigation window.
        .onChange(of: navState) { _, newNav in
            #if DEBUG
            log("【RootPanelView】navState → \(newNav)", category: .panel)
            #endif
        }
    }

    // MARK: - Route branches

    /// Main panel branch: `PanelContainerView` wrapping `PanelMainView`.
    /// Rendered when `savedNavState` is `.none` or `.main`.
    @ViewBuilder private var mainBranch: some View {
        PanelContainerView(
            content: PanelMainView(
                onStepTap: { job, step in
                    #if DEBUG
                    log("【RootPanelView】onStepTap — navigating to stepLog job=\(job.id) step=\(step.number)", category: .panel)
                    #endif
                    appState.savedNavState = .stepLog(job: job, step: step)
                },
                onSelectSettings: onSelectSettings
            )
        )
    }

    /// Settings branch: `PanelContainerView` wrapping `SettingsView`.
    /// Rendered when `savedNavState` is `.settings`.
    @ViewBuilder private var settingsBranch: some View {
        PanelContainerView(
            content: SettingsView(
                onBack: onBack,
                appState: appState
            )
        )
    }

    /// Step-log branch: `StepLogView` for the given job and step.
    /// Rendered when `savedNavState` is `.stepLog`. No `PanelContainerView` wrapper —
    /// `StepLogView` has no sheets and must not receive a double dim overlay.
    @ViewBuilder private func stepLogBranch(job: ActiveJob, step: GitHubStep) -> some View {
        StepLogView(
            job: job,
            step: step,
            onBack: onStepBack
        )
    }

    // MARK: - Route identity key

    /// String identity key for `.id(navState)`, unique per distinct route.
    private var navState: String {
        switch appState.savedNavState {
        case .none, .main:                      return "main"
        case .settings:                         return "settings"
        case .stepLog(let job, let step):       return "stepLog-\(job.id)-\(step.number)"
        }
    }
}
