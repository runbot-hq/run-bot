// PanelMainView.swift
// RunBot
import GitHubClient
import RunBotCore
import SwiftUI
// REGRESSION GUARD -- DO NOT REMOVE - see regression history (ref #52 #54 #57 #375 #376 #377)
//
// ARCHITECTURE: MBKPopoverController sizing contract (as of #2264)
// Dynamic height AND width driven by MBKPopoverController's GeometryReader in wrapped().
// sizingOptions = [] disables AppKit's automatic hosting-controller size negotiation.
// Every pixel of popover size comes from SwiftUI reporting the correct geo.size.
//
// SIZING RULES:
// RULE 1: Root VStack ends with .fixedSize() — both axes.
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
// RULE 5: actionsSection ScrollView uses .frame(height: scrollViewHeight) — a
//         @State value, NOT maxHeight. This is the core anti-jump contract:
//
//         The problem: .frame(maxHeight:) lets the ScrollView grow when content
//         grows (row expand), propagating through .fixedSize() → MBK → popover
//         resize → visible jump of the entire panel.
//
//         The solution: measure actionsSectionContent's natural height via a
//         hidden GeometryReader (contentHeightReader). Store it in @State
//         scrollViewHeight, capped at screenScrollMaxHeight. Only update
//         scrollViewHeight when the visible ROW COUNT changes — ignore height
//         changes caused by row expand/collapse (those are internal scroll content).
//
//         This gives dynamic panel height (grows with rows) without jump on expand.
//
// RULE 6: systemStats MUST run only while the panel is open.
// RULE 7: RunnerStore self-schedules via its own adaptive timer.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//
// NSPopover provides its own glass chrome automatically.
// Do NOT add .background() or NSVisualEffectView at this level.
struct PanelMainView: View {
    let onStepTap: (ActiveJob, GitHubStep) -> Void
    let onSelectSettings: () -> Void
    var localRunnerStore: LocalRunnerStore = .shared
    @Environment(PanelVisibilityState.self) private var panelVisibilityState: PanelVisibilityState
    @Environment(AppState.self) private var appState
    @State private var systemStats = SystemStatsViewModel()
    @State private var visibleCount: Int = 10
    @State private var displayTick: Int = 0
    @State private var displayTickTask: Task<Void, any Error>?
    /// Stable height fed to the ScrollView .frame(height:).
    /// Updated only when the visible row count changes, NOT when a row expands.
    /// Starts at 0; set on first content measurement via contentHeightReader.
    @State private var scrollViewHeight: CGFloat = 0
    /// The row count that produced the current scrollViewHeight.
    /// Used to detect genuine row-count changes vs. expand-caused height changes.
    @State private var heightForRowCount: Int = -1

    init(
        onStepTap: @escaping (ActiveJob, GitHubStep) -> Void,
        onSelectSettings: @escaping () -> Void
    ) {
        self.onStepTap = onStepTap
        self.onSelectSettings = onSelectSettings
    }

    private var screenScrollMaxHeight: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) * 0.80
    }

    private var visibleRowCount: Int {
        min(appState.runnerState.actions.count, visibleCount)
    }

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
            if let aid = local.agentId, busyIds.contains(aid) { return true }
            if busyNames.contains(local.runnerName) { return true }
            return false
        }
    }

    var body: some View {
        // DEBUG — jump diagnosis. Remove after fix confirmed.
        log("【PanelMainView.body】rendered", category: .general)
        return VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                onSelectSettings: onSelectSettings
            )
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
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await localRunnerStore.refresh() }
                }
            actionsSectionScrollable
        }
        // RULE 1: .fixedSize() is LOAD-BEARING.
        .fixedSize()
        // DEBUG: confirm root VStack no longer changes size on row expand.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        log("【PanelMainView.rootVStack.geo】onAppear size=\(geo.size)", category: .general)
                    }
                    .onChange(of: geo.size) { old, new in
                        log("【PanelMainView.rootVStack.geo】onChange \(old) → \(new)", category: .general)
                    }
            }
        )
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
        .onChange(of: appState.runnerState.actions) { old, new in
            if new.count < old.count { visibleCount = 10 }
        }
    }

    /// The scrollable actions list.
    ///
    /// The ScrollView is given a FIXED .frame(height: scrollViewHeight) — never maxHeight.
    /// scrollViewHeight is driven by contentHeightReader below and only updates when
    /// the visible row count changes, so row expand never triggers a panel resize.
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
                // Measure the natural collapsed height of the content.
                // This overlay is always present so we always have a fresh measurement.
                // We selectively apply updates in applyContentHeight() below.
                .background(
                    GeometryReader { geo in
                        Color.clear.onAppear {
                            applyContentHeight(geo.size.height)
                        }
                        .onChange(of: geo.size.height) { _, h in
                            applyContentHeight(h)
                        }
                    }
                )
        }
        // RULE 5: fixed height driven by @State scrollViewHeight, not maxHeight.
        // scrollViewHeight is only updated on row count change, not on row expand.
        .frame(height: scrollViewHeight > 0 ? scrollViewHeight : screenScrollMaxHeight)
        // DEBUG: confirm scroll frame no longer changes on row expand.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        log("【PanelMainView.scrollView.geo】onAppear size=\(geo.size)", category: .general)
                    }
                    .onChange(of: geo.size) { old, new in
                        log("【PanelMainView.scrollView.geo】onChange \(old) → \(new)", category: .general)
                    }
            }
        )
    }

    /// Updates scrollViewHeight only when the visible row count has changed.
    ///
    /// Height changes caused by row expand/collapse are ignored because they
    /// happen while heightForRowCount == visibleRowCount (the count didn't change).
    /// This keeps the ScrollView frame stable during expand — no jump.
    private func applyContentHeight(_ measuredHeight: CGFloat) {
        let currentCount = visibleRowCount
        guard currentCount != heightForRowCount else {
            // Row count unchanged — this is an expand/collapse height change. Ignore.
            log("【PanelMainView.applyContentHeight】ignored h=\(measuredHeight) count=\(currentCount) (expand/collapse)", category: .general)
            return
        }
        let clamped = min(measuredHeight, screenScrollMaxHeight)
        log("【PanelMainView.applyContentHeight】apply h=\(clamped) (measured=\(measuredHeight), rowCount \(heightForRowCount)→\(currentCount))", category: .general)
        scrollViewHeight = clamped
        heightForRowCount = currentCount
    }

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
        .padding(.vertical, 4)
    }

    @ViewBuilder private var loadMoreButton: some View {
        let nextBatch = min(10, appState.runnerState.actions.count - visibleCount)
        if nextBatch > 0 {
            Button { visibleCount += nextBatch } label: {
                Text("Load \(nextBatch) more workflows…")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    @MainActor private func startDisplayTickTimer() {
        stopDisplayTickTimer()
        displayTickTask = Task(name: "displayTick") { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(1))
                displayTick &+= 1
            }
        }
    }

    @MainActor private func stopDisplayTickTimer() {
        displayTickTask?.cancel()
        displayTickTask = nil
    }

    private func fetchErrorBanner(_ error: any Error) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            Text("Fetch error — \(error.localizedDescription)")
                .font(.caption).foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }

    private var rateLimitBanner: some View {
        withExtendedLifetime(displayTick) {}
        let countdownLabel: String
        if let resetDate = appState.runnerState.rateLimitResetDate {
            let remaining = max(0, resetDate.timeIntervalSinceNow)
            if remaining < 1 {
                countdownLabel = "resuming…"
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
