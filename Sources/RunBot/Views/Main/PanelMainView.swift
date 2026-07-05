// PanelMainView.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI
// REGRESSION GUARD -- DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: NSPopover + sizingOptions=.preferredContentSize
// Dynamic height AND width driven by KVO on preferredContentSize.
// AppDelegate updates popover.contentSize (both dimensions) when either changes.
// Updating contentSize resizes the popover in place -- the arrow stays anchored
// to the original positioningRect. Only popover.show() jumps; contentSize does not.
//
// RULE 1: Root VStack uses .frame(minWidth:maxWidth:alignment:)
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
// RULE 5: actionsSection is wrapped in a ScrollView capped at screenScrollMaxHeight.
// RULE 6: systemStats MUST run only while the panel is open.
// RULE 7: RunnerStore self-schedules via its own adaptive timer.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//
// NSPopover provides its own glass chrome automatically.
// Do NOT add .background() or NSVisualEffectView at this level.
/// Root panel view rendered inside the NSPopover.
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
    @Environment(RunnerState.self) private var runnerState: RunnerState
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

    /// Maximum scroll height for the actions section (80% of visible screen height).
    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    /// Local runners currently executing a job inside an in-progress workflow group.
    ///
    /// Reads GitHub-side state (`actions`, `jobs`, `runners`) and local runner state
    /// (`localRunners`) from `runnerState` — the single observable source of truth
    /// injected via the SwiftUI environment from `AppDelegate.wrapEnv`.
    private var activeLocalRunners: [RunnerModel] {
        guard runnerState.actions.contains(where: { $0.groupStatus == .inProgress }) else { return [] }
        let activeNamesFromJobs = Set(
            runnerState.jobs.filter { $0.jobStatus == .inProgress }.compactMap { $0.runnerName }
        )
        let busyRunners = runnerState.runners.filter { $0.busy }
        let busyIds = Set(busyRunners.compactMap { $0.id })
        let busyNames = Set(busyRunners.map { $0.name })
        return runnerState.localRunners.filter { local in
            if activeNamesFromJobs.contains(local.runnerName) { return true }
            if let aid = local.agentId, busyIds.contains(aid) { return true }
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
            .onAppear { systemStats.start() }
            Divider()
            if let error = runnerState.fetchError {
                fetchErrorBanner(error)
                Divider()
            }
            if runnerState.isRateLimited { rateLimitBanner; Divider() }
            if !activeLocalRunners.isEmpty {
                SectionHeaderLabel(title: "Local Runners")
                PanelLocalRunnerRow(runners: activeLocalRunners)
            }
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await localRunnerStore.refresh() }
                }
            actionsSectionScrollable
        }
        .frame(minWidth: 280, maxWidth: 900, alignment: .top)
        .onAppear {
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            systemStats.stop()
            stopDisplayTickTimer()
        }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open { systemStats.start() } else { systemStats.stop() }
        }
        // Reset the visible row count only when the list shrinks (e.g. a runner is removed),
        // not on every poll update — avoids snapping the user back mid-scroll.
        .onChange(of: runnerState.actions) { old, new in
            if new.count < old.count { visibleCount = 10 }
        }
    }

    /// Scrollable container for the actions section, capped at `screenScrollMaxHeight`.
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
        }
        .frame(maxHeight: screenScrollMaxHeight)
    }

    /// Workflow rows and the load-more button, rendered inside the scroll container.
    private var actionsSectionContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(title: "Workflows")
            if runnerState.actions.isEmpty {
                Text("No recent workflows")
                    .font(.caption).foregroundColor(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                let visible = Array(runnerState.actions.prefix(visibleCount))
                ForEach(visible) { group in
                    ActionRowView(group: group, tick: displayTick, onStepTap: onStepTap)
                }
                loadMoreButton
            }
        }
        .padding(.vertical, 4)
    }

    /// "Load N more workflows" button; hidden when all workflows are already visible.
    @ViewBuilder private var loadMoreButton: some View {
        let nextBatch = min(10, runnerState.actions.count - visibleCount)
        if nextBatch > 0 {
            Button { visibleCount += nextBatch } label: {
                Text("Load \(nextBatch) more workflows\u{2026}")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    /// Starts the 1-second structured `displayTick` loop. Cancels any existing task first.
    ///
    /// Sleep-first: fires 1 s after start, matching the prior `Timer.scheduledTimer` behaviour.
    /// No open-state gate — RULE 9: displayTick runs always while the view is alive.
    /// Named "displayTick" for Instruments visibility (RG6).
    /// `try` (not `try?`) on Task.sleep propagates CancellationError cleanly so the loop
    /// exits immediately on cancel without executing a spurious post-cancel tick.
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

    /// Inline error banner shown when `runnerState.fetchError` is non-nil.
    ///
    /// Displays a truncated error description. Dismisses automatically on the next
    /// successful fetch cycle when `applyFetchResult` clears `fetchError`.
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
    /// The label refreshes every second because `displayTick` is threaded through
    /// `body → actionsSectionContent → ActionRowView(tick:)`. The `withExtendedLifetime`
    /// call here makes the read intent explicit but does not itself register a new dependency.
    private var rateLimitBanner: some View {
        withExtendedLifetime(displayTick) {} // makes read intent explicit; actual refresh is driven by the tick: param chain in body
        let countdownLabel: String
        if let resetDate = runnerState.rateLimitResetDate {
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
