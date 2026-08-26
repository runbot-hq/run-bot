// AppNavigationSplitView.swift
// RunBot

import RunBotCore
import SwiftUI

/// Root three-column navigation shell: sidebar, content, and detail.
///
/// Owns the top-level sidebar selection and the shared workflow selection so
/// the content column (workflow hierarchy) and detail column (step log) stay
/// in sync (issue #2880).
///
/// ## SIZING CONTRACT — restored lessons from the popover era
/// (refs #375–377 side-jump regressions, #2278/#2279 stale-cap regressions,
/// #2305 width inheritance)
///
/// The windowed shell replaced the anchored menu-bar panel, but the failure
/// modes that shaped that design still apply to window/column sizing:
///
/// - ONE MEASUREMENT, ONE OWNER. Exactly one layer may measure content and
///   derive a size from it. The old panel regressed repeatedly when two
///   independent height caps and three measurement sources (a content
///   GeometryReader, `.preferredContentSize`, and a manual `setFrame`) could
///   disagree. Here the `Window` scene owns the min/default size and each
///   column owns only its width range — no view below the shell re-measures.
/// - NEVER size a window from `.preferredContentSize`, an invisible helper
///   pass, or a GeometryReader feedback loop. That was the direct cause of
///   the side-jump family of bugs (#375–377); the fix each time was to
///   collapse to a single owner.
/// - WRAPPERS MUST NOT IMPOSE WIDTH ON ROUTED CHILDREN (#2305). The old
///   popover wrapper applied its own `minWidth/maxWidth`, which stretched the
///   fixed-width Settings screen to the list's width. Width ranges live where
///   the column lives: `navigationSplitViewColumnWidth` here, and per-view
///   caps (e.g. the 820 pt readability cap in `SettingsDetailView`) in the
///   views that own them.
struct AppNavigationSplitView: View {
    /// Currently selected sidebar destination. Defaults to Workflows.
    @State private var selection: AppDestination? = .workflows

    /// Shared workflow → job → step selection. Owned at the shell level
    /// because the hierarchy and step-log columns both read and mutate it.
    @State private var workflowSelection = WorkflowSelection()

    /// Shared settings section selection. Owned at the shell level so the
    /// content column (list) and detail column (section view) stay in sync.
    @State private var settingsSelection: SettingsSection? = .authentication

    /// Shared runner selection. Owned here so the content list and detail column
    /// resolve the same model. (#2900)
    @State private var selectedRunnerID: RunnerModel.ID?

    /// Shared scope selection. Owned here so the content list and detail column
    /// resolve the same model. (#2900)
    @State private var selectedScopeID: ScopeEntry.ID?

    /// Runner store forwarded from the composition root.
    let runnerState: RunnerState
    /// Configured local-runner store forwarded from the composition root.
    let localRunnerStore: LocalRunnerStore
    /// Settings services forwarded from the composition root.
    let settingsDependencies: SettingsDependencies
    /// Shared log fetcher — owned by `AppDependencies`, threaded down
    /// via `@Binding` so the ZIP cache survives column navigations.
    @Binding var logFetcher: LogFetcher

    /// The top-level split-view layout.
    var body: some View {
        NavigationSplitView {
            AppSidebarColumnView(selection: $selection)
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 210,
                    max: 260
                )
        } content: {
            AppContentColumnView(
                selection: selection,
                runnerState: runnerState,
                localRunnerStore: localRunnerStore,
                workflowSelection: workflowSelection,
                settingsSelection: $settingsSelection,
                selectedRunnerID: $selectedRunnerID,
                selectedScopeID: $selectedScopeID
            )
        } detail: {
            AppDetailColumnView(
                selection: selection,
                runnerState: runnerState,
                workflowSelection: workflowSelection,
                settingsSelection: settingsSelection,
                settingsDependencies: settingsDependencies,
                selectedRunnerID: selectedRunnerID,
                selectedScopeID: selectedScopeID,
                logFetcher: $logFetcher
            )
        }
        .navigationSplitViewStyle(.balanced)
        // Content min-size floor. Must stay in sync with
        // `.windowResizability(.contentMinSize)` + `.defaultSize` in
        // RunBotDesktopApp — two sources that must never disagree (see the
        // one-measurement rule above).
        .frame(minWidth: 720, minHeight: 480)
    }
}
