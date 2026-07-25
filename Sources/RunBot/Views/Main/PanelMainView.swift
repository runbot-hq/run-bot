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
// RULE 1: Root VStack ends with .fixedSize() — both axes. LOAD-BEARING for MBK.
//         Without this, the view fills whatever contentSize MBK last wrote,
//         the background GR reports that same size back, and applyContentSize
//         sees no change — height is frozen at the initial value forever.
// RULE 2: ALL rows use .padding(.horizontal, 12)
// RULE 3: Job row HStack Spacer() is LOAD-BEARING.
// RULE 4: RunnerViewModel.reload() uses withAnimation(nil).
// RULE 5: actionsSectionContent uses .fixedSize(horizontal: false, vertical: true)
//         so SwiftUI measures its true natural height before the ScrollView clips it.
//         A GeometryReader in the content background captures that height into
//         @State scrollViewHeight (capped at screenScrollMaxHeight).
//         The ScrollView is given .frame(height: scrollViewHeight) — a fixed value,
//         not maxHeight — so MBK sees exactly min(contentHeight, cap) and sizes
//         the popover accordingly.
//         All height changes (row add AND row expand) are applied immediately;
//         no row-count guard. MBK grows the panel downward on expand.
// RULE 6: systemStats MUST run only while the panel is open.
// RULE 7: RunnerStore self-schedules via its own adaptive timer.
// RULE 9: displayTick fires every 1 second ALWAYS (no open-state gate).
//
// SIDE-JUMP SAFETY:
//         The GR in RULE 5 only reads geo.size.height. It does not affect width.
//         Side-jumping is caused by stale anchorPoint.x in MBK's applyContentSize
//         (see issue #2265 Bug 3 / #2268) — fixed in MBK PopoverController:
//         anchorPoint.x is now captured from the status button's screen midX
//         (not window.frame.midX), and setFrameOrigin is skipped when only
//         height changes (width delta ≤ 1pt). No changes needed in this file.
//
// HEADER STABILITY (RULE 10):
//         PanelHeaderView has .fixedSize() at the call site. SwiftUI measures it
//         once at its natural content-driven height and never re-negotiates it
//         during subsequent VStack re-layouts triggered by scrollViewHeight changes.
//         The Divider below the header is therefore always at a fixed Y.
//         On macOS 26, GlassEffectContainer can report slightly different preferred
//         heights under layout pressure — .fixedSize() prevents that entirely.
//
// CAP ALIGNMENT (RULE 11):
//         screenScrollMaxHeight multiplier (0.80) MUST match AppDelegate.maxHeight
//         multiplier. Both derive from visibleFrame.height. Using different values
//         creates a gap where MBK clamps the popover at a height SwiftUI didn't
//         expect, forcing a re-layout that compresses the header.
//         ❌ NEVER change this multiplier without also changing AppDelegate.maxHeight.
//
// TOTAL PANEL CAP (RULE 12):
//         screenScrollMaxHeight subtracts the measured headerHeight so that the
//         full panel (header + divider + scroll) stays within 0.80 * visibleFrame.height.
//         headerHeight starts at 0 and is updated from the header GeometryReader on
//         first appear. No fixed pixel values — the header measures its own height.
//
// NSPopover provides its own glass chrome automatically.
// Do NOT add .background() or NSVisualEffectView at this level.
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
    /// View model for CPU/memory stats displayed in the header.
    @State private var systemStats = SystemStatsViewModel()
    /// Number of workflow rows currently shown in the actions section.
    @State private var visibleCount: Int = 10
    /// Increments every second to drive relative-time label refreshes without re-polling.
    @State private var displayTick: Int = 0
    /// Structured task driving the 1-second `displayTick` loop.
    @State private var displayTickTask: Task<Void, any Error>?
    /// Height of the ScrollView frame, driven by the content GeometryReader (RULE 5).
    /// Starts at 0 (no constraint) until the first measurement fires on appear.
    @State private var scrollViewHeight: CGFloat = 0
    /// Measured natural height of PanelHeaderView. Captured once on appear (RULE 12).
    /// Used to subtract from the 0.80 cap so the full panel never overflows the screen.
    @State private var headerHeight: CGFloat = 0

    /// Creates a `PanelMainView`.
    init(
        onStepTap: @escaping (ActiveJob, GitHubStep) -> Void,
        onSelectSettings: @escaping () -> Void
    ) {
        self.onStepTap = onStepTap
        self.onSelectSettings = onSelectSettings
    }

    /// Maximum height for the scroll section.
    /// = 0.80 * visibleFrame.height − headerHeight (measured, not fixed).
    /// This ensures the full panel (header + divider + scroll) stays within the 0.80 cap.
    /// ❌ MUST match AppDelegate.maxHeight multiplier. See RULE 11 / CAP ALIGNMENT.
    /// ❌ NEVER use fixed pixel values here. headerHeight is content-derived (RULE 12).
    private var screenScrollMaxHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let cap = visibleHeight * 0.80 - headerHeight
        log("【PanelMainView】screenScrollMaxHeight visibleHeight=\(visibleHeight) headerHeight=\(headerHeight) cap=\(cap) multiplier=0.80", category: .general)
        return cap
    }

    /// Local runners currently executing a job inside an in-progress workflow group.
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
            if busyNames.contains(local.runnerName) { return true }
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                onSelectSettings: onSelectSettings
            )
            // RULE 10: LOAD-BEARING — do not remove.
            .fixedSize()
            // Capture header's natural height for RULE 12 scroll cap adjustment.
            // DEBUG: also logs header height changes. Remove debug logs before merge.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            headerHeight = geo.size.height
                            log("【header.geo】onAppear h=\(geo.size.height)", category: .general)
                        }
                        .onChange(of: geo.size.height) { old, new in
                            headerHeight = new
                            log("【header.geo】onChange \(old) → \(new)  ← HEADER HEIGHT CHANGED", category: .general)
                        }
                }
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
        // RULE 1: LOAD-BEARING — do not remove or change.
        .fixedSize()
        // DEBUG: log root VStack total height changes. Remove before merge.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        log("【rootVStack.geo】onAppear h=\(geo.size.height)", category: .general)
                    }
                    .onChange(of: geo.size.height) { old, new in
                        log("【rootVStack.geo】onChange \(old) → \(new)", category: .general)
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

    // MARK: - Scroll section

    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                let cap = screenScrollMaxHeight
                                let capped = min(geo.size.height, cap)
                                log("【scrollContent.geo】onAppear raw=\(geo.size.height) cap=\(cap) capped=\(capped)", category: .general)
                                scrollViewHeight = capped
                            }
                            .onChange(of: geo.size.height) { old, new in
                                let cap = screenScrollMaxHeight
                                let capped = min(new, cap)
                                log("【scrollContent.geo】onChange raw \(old) → \(new)  cap=\(cap)  scrollViewHeight \(scrollViewHeight) → \(capped)", category: .general)
                                scrollViewHeight = capped
                            }
                    }
                )
        }
        .frame(height: scrollViewHeight > 0 ? scrollViewHeight : nil)
        // DEBUG: log ScrollView frame height changes. Remove before merge.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        log("【scrollView.geo】onAppear h=\(geo.size.height)", category: .general)
                    }
                    .onChange(of: geo.size.height) { old, new in
                        log("【scrollView.geo】onChange \(old) → \(new)", category: .general)
                    }
            }
        )
    }

    // MARK: - Content

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
                Text("Load \(nextBatch) more workflows\u{2026}")
                    .font(.caption).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    // MARK: - Display tick timer

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

    // MARK: - Banners

    private func fetchErrorBanner(_ error: any Error) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.red).font(.caption)
            Text("Fetch error \u{2014} \(error.localizedDescription)")
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
            Text("GitHub rate limit reached \u{2014} \(countdownLabel)").font(.caption).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 4)
    }
}
