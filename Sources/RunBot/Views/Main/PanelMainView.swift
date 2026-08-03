// PanelMainView.swift
// RunBot
import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI
// REGRESSION GUARD -- DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: MBKPanelController sizing contract (anchored-panel rewrite)
//
// This view no longer measures itself. MenuBarKit caps the height, reads the
// resulting intrinsic size off its NSHostingView, and makes that the window
// frame; the window frame is then re-proposed to this view. One measurement,
// one owner.
//
// WIDTH IS THIS VIEW'S RESPONSIBILITY (changed after device testing of #2305).
// MenuBarKit used to apply `.frame(minWidth:maxWidth:)` in its own wrapper, so
// the range was inherited by every route and stretched the fixed-width Settings
// screen (480pt) to the list's width. MBK now caps only the height and the
// screen width; the range lives on this view's root instead (see RULE 11).
//
// WHAT WAS DELETED HERE AND WHY (do not bring any of it back):
//   • @State scrollViewHeight + the content GeometryReader that fed it
//   • @State headerHeight + the header GeometryReader that fed it
//   • screenScrollMaxHeight — the 80% cap now lives in MenuBarKit, resolved
//     live against NSScreen on every open (AppDelegate.panelHeightMultiplier is
//     passed through as `maxHeightFraction`)
//   • .frame(height: scrollViewHeight > 0 ? ... : nil) on the ScrollView
//   • the root .fixedSize() — MenuBarKit's unspecified-proposal measurement pass
//     already gives us content-driven sizing, and a .fixedSize() here would make
//     the ScrollView ignore the capped proposal and overflow instead of scroll
//   • isMenuBarHidden and the NSApp.windows iteration behind it — MenuBarKit
//     positions from the live status-button anchor, so this view never needs to
//     know whether the menu bar is hidden
//   • the debug-only root/ScrollView GeometryReaders that existed to trace the
//     old pipeline
// Together these were the machinery behind #2278 and #2279: two independent
// caps and three measurement sources that could disagree with each other.
//
// SIZING RULES (what remains, all still load-bearing):
// RULE 1: The height cap belongs to MenuBarKit.
//         ❌ NEVER add a .frame(maxHeight:) or a screen-derived cap in this file.
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
// RULE 5: actionsSectionContent keeps .fixedSize(horizontal: false, vertical: true)
//         so the scroll content reports its true natural height and the panel can
//         size to it while it is shorter than the cap.
// RULE 6: systemStats MUST run only while the panel is open.
// RULE 7: RunnerStore self-schedules via its own adaptive timer.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
// RULE 10 (HEADER STABILITY): PanelHeaderView keeps .fixedSize() at the call
//         site. On macOS 26, GlassEffectContainer reports slightly different
//         preferred heights under layout pressure on macOS 26; .fixedSize() pins it so the
//         Divider below never moves.
// RULE 11 (WIDTH OWNERSHIP): the root carries
//         .frame(minWidth: RBMetrics.panelListMinWidth, maxWidth: RBMetrics.panelListMaxWidth).
//         ❌ NEVER move it into MenuBarKit — it would apply to Settings too.
// RULE 12 (TOP ALIGNMENT): the root carries
//         .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//         AFTER the width frame. Without this, when the window expands between
//         MEASURE passes (stale fittingSize open → settled onGeometryChange resize),
//         SwiftUI re-centres the VStack in the new space instead of keeping it at the top.
//
// The panel's Liquid Glass bubble and arrow are drawn by MenuBarKit in AppKit
// (`MBKPanelChromeView`: an NSGlassEffectView body plus a rotated NSGlassEffectView
// arrow), one layer *below* this view —
// exactly where NSPopover used to put its chrome. That is deliberate: a SwiftUI
// `.glassEffect` ancestor flattens every GlassEffectContainer in this file (the
// metric bars, the SUCCESS/FAILED tags, every chip), which is what happened on
// the first attempt at the anchored panel.
// Do NOT add .background(), a root .glassEffect(), or an NSVisualEffectView here.

/// Root panel view rendered inside the MenuBarKit panel.
struct PanelMainView: View {
    /// Called when user taps a step row.
    let onStepTap: (ActiveJob, GitHubStep) -> Void
    /// Called when the user taps the settings gear button.
    let onSelectSettings: () -> Void
    /// Injected local runner store — used to trigger refresh on appear.
    var localRunnerStore: LocalRunnerStore = .shared
    /// Panel open/close and transient-hide state from the environment.
    @Environment(PanelVisibilityState.self) private var panelVisibilityState: PanelVisibilityState
    /// Core runner/job/action/rate-limit state injected from AppDelegate.wrapEnv.
    @Environment(AppState.self) private var appState
    /// Panel controller handle injected from AppDelegate.wrapEnv — used to
    /// invalidate content size when the list grows and standard KVO is insufficient.
    @Environment(PanelControllerHandle.self) private var panelControllerHandle
    /// View model for CPU/memory stats displayed in the header.
    @State private var systemStats = SystemStatsViewModel()
    /// Number of workflow rows currently shown in the actions section.
    @State private var visibleCount: Int = 10
    /// Increments every second to drive relative-time label refreshes without re-polling.
    @State private var displayTick: Int = 0
    /// Structured task driving the 1-second `displayTick` loop; managed by `startDisplayTickTimer()`.
    /// Named "displayTick" for visibility in Instruments (RG6).
    @State private var displayTickTask: Task<Void, any Error>?

    /// Creates a `PanelMainView`.
    init(
        onStepTap: @escaping (ActiveJob, GitHubStep) -> Void,
        onSelectSettings: @escaping () -> Void
    ) {
        self.onStepTap = onStepTap
        self.onSelectSettings = onSelectSettings
    }

    /// Local runners currently executing a job inside an in-progress workflow group.
    ///
    /// Reads GitHub-side state (`actions`, `jobs`, `runners`) and local runner state
    /// (`localRunners`) from `runnerState` — the single observable source of truth
    /// injected via the SwiftUI environment from `AppDelegate.wrapEnv`.
    private var activeLocalRunners: [RunnerModel] {
        guard appState.runnerState.actions.contains(where: { $0.groupStatus == .inProgress }) else { return [] }
        let activeNamesFromJobs = Set(
            appState.runnerState.jobs.filter { $0.jobStatus == .inProgress }.compactMap { $0.runnerName }
        )
        let busyRunners = appState.runnerState.runners.filter { $0.busy }
        let busyIds = Set(busyRunners.compactMap { $0.id })
        let busyNames = Set(busyRunners.map { $0.name })
        return appState.runnerState.localRunners.filter { local in
            if activeNamesFromJobs.contains(local.runnerName) { return true }
            if let aid = local.apiId, busyIds.contains(aid) { return true }
            if busyNames.contains(local.runnerName) { return true }
            return false
        }
    }

    /// Root body -- header, optional error/rate-limit banners, local runner rows, and the scrollable actions section.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                onSelectSettings: onSelectSettings
            )
            .fixedSize()
            .onAppear { systemStats.start() }
            Divider()
            if let error = appState.runnerState.fetchError {
                fetchErrorBanner(error)
                Divider()
            }
            if appState.runnerState.isRateLimited { rateLimitBanner; Divider() }
            if !activeLocalRunners.isEmpty {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: activeLocalRunners)
            }
            // Color.clear trigger for localRunnerStore.refresh() on appear.
            // Zero-size so it has no visual presence or layout impact.
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await localRunnerStore.refresh() }
                }
            actionsSectionScrollable
        }
        .frame(minWidth: RBMetrics.panelListMinWidth, maxWidth: RBMetrics.panelListMaxWidth)
        // Pin the VStack to the top-leading corner of the window. Without this,
        // when the window grows between MEASURE passes SwiftUI re-centres the
        // VStack vertically, making the list appear to float down the screen.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            #if DEBUG
            log("【PanelMainView】onAppear panelOpen=\(panelVisibilityState.isOpen)", category: .panel)
            #endif
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            #if DEBUG
            log("【PanelMainView】onDisappear", category: .panel)
            #endif
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { _, newOpen in
            #if DEBUG
            log("【PanelMainView】panelVisibilityState.isOpen → \(newOpen)", category: .panel)
            #endif
            if newOpen { systemStats.start() } else { systemStats.stop() }
        }
        .onChange(of: appState.runnerState.actions) { oldActions, newActions in
            #if DEBUG
            log("【PanelMainView】actions count → \(newActions.count)", category: .panel)
            #endif
            if newActions.count < oldActions.count { visibleCount = 10 }
            panelControllerHandle.remeasure()
        }
        .onChange(of: appState.runnerState.runners) { _, _ in
            panelControllerHandle.remeasure()
        }
        .onChange(of: appState.runnerState.jobs) { _, _ in
            panelControllerHandle.remeasure()
        }
    }

    // MARK: - Scroll section

    /// Scrollable container for the actions section.
    /// Height is driven by `preferredContentSize` KVO through MenuBarKit's sizing pipeline (see RULE 5).
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Content

    /// Workflow rows and the load-more button, rendered inside the scroll container.
    private var actionsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(title: "Workflows")
            if appState.runnerState.actions.isEmpty {
                Text("No recent workflows")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(appState.runnerState.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(group: group, tick: displayTick, onStepTap: onStepTap)
                }
                loadMoreButton
            }
        }
    }

    /// "Load N more workflows" button; hidden when all workflows are already visible.
    @ViewBuilder private var loadMoreButton: some View {
        let nextBatch = min(10, appState.runnerState.actions.count - visibleCount)
        if nextBatch > 0 {
            Button { visibleCount += nextBatch } label: {
                Text("Load \(nextBatch) more workflows\u{2026}")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Display tick timer

    /// Starts the 1-second structured `displayTick` loop. Cancels any existing task first.
    ///
    /// No open-state gate — RULE 9: displayTick runs always while the view is alive.
    /// Named "displayTick" for Instruments visibility (RG6).
    /// `@MainActor` is explicit so the compiler statically verifies that `displayTickTask`
    /// (a `@State`-backed property) is always mutated on the main actor.
    @MainActor private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTask = Task(name: "displayTick") { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                displayTick &+= 1
            }
        }
    }

    /// Cancels and nils the `displayTick` task.
    /// `@MainActor` matches `startDisplayTickTimer()` — both mutate `displayTickTask`.
    @MainActor private func stopDisplayTickTimer() {
        displayTickTask?.cancel()
        displayTickTask = nil
    }

    // MARK: - Banners

    /// Inline error banner shown when `appState.runnerState.fetchError` is non-nil.
    ///
    /// Displays a truncated error description. Dismisses automatically on the next
    /// successful fetch cycle when `fetchError` is cleared.
    /// Stale `runners`/`jobs`/`actions` remain visible below the banner so the user
    /// still sees the last-known state while connectivity is degraded.
    private func fetchErrorBanner(_ error: any Error) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            Text("Fetch error — \(error.localizedDescription)")
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    /// Rate-limit warning banner showing a countdown to API reset.
    ///
    /// WHY withExtendedLifetime(displayTick): makes the per-second dependency explicit
    /// to both the compiler and future readers without changing runtime behaviour.
    private var rateLimitBanner: some View {
        withExtendedLifetime(displayTick) {}
        let countdownLabel: String
        if let resetDate = appState.runnerState.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming\u{2026}"
            } else if remaining < 60 {
                countdownLabel = "resets in \(Int(remaining))s"
            } else {
                let mins = Int(remaining) / 60; let secs = Int(remaining) % 60
                countdownLabel = String(format: "resets in %dm %02ds", mins, secs)
            }
        } else { countdownLabel = "pausing polls" }
        return HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.caption)
            Text("GitHub rate limit reached -- \(countdownLabel)").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
