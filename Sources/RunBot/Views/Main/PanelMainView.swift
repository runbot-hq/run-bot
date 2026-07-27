// PanelMainView.swift
// RunBot
import AppKit
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
//         (see issue #2265 Bug 3) — orthogonal to our vertical GR.
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
//         screenScrollMaxHeight multiplier MUST match AppDelegate.panelHeightMultiplier.
//         Both derive from visibleFrame.height. Using different values creates a gap
//         where MBK clamps the popover at a height SwiftUI didn't expect, forcing a
//         re-layout that compresses the header.
//         ❌ NEVER inline the multiplier value here — always reference
//            AppDelegate.panelHeightMultiplier.
//
// TOTAL PANEL CAP (RULE 12):
//         screenScrollMaxHeight subtracts the measured headerHeight so that the
//         full panel (header + divider + scroll) stays within
//         AppDelegate.panelHeightMultiplier * visibleFrame.height.
//         headerHeight starts at 0 and is updated from the header GeometryReader on
//         first appear. No fixed pixel values — the header measures its own height.
//
// MULTIPLE GEOMETRYREADERS — WHY THIS IS INTENTIONAL AND NOT REDUNDANT:
//         There are three distinct GRs in this file: one on the header, one on
//         actionsSectionContent, and one on the ScrollView frame. Each measures
//         a different thing:
//           • Header GR → headerHeight (used to tighten the scroll cap, RULE 12)
//           • Content GR → scrollViewHeight (the full natural content height, RULE 5)
//           • ScrollView GR → debug logging only (does not write any state)
//         Merging them would conflate header height with scroll content height and
//         break the RULE 12 cap calculation. Each GR is in a .background() so it
//         does not participate in layout and cannot influence the size it is measuring.
//         ❌ NEVER merge these three GeometryReaders into one.
//         ❌ NEVER move a GR out of .background() — it will influence its own measurement.
//
// WHY .frame(height: scrollViewHeight > 0 ? scrollViewHeight : nil) NOT maxHeight:
//         Using .frame(maxHeight:) gives SwiftUI permission to make the ScrollView
//         any height up to the cap. MBK's GeometryReader then reports that offered
//         height rather than the content's actual height, and the popover over-sizes.
//         Using a fixed .frame(height:) forces the ScrollView to report exactly what
//         we measured. The `> 0 ? ... : nil` guard keeps the constraint absent on the
//         first layout pass (before the content GR has fired) so SwiftUI can perform
//         the initial measurement unconstrained.
//
// DUAL scrollViewHeight RESET — WHY TWO SITES AND WHY THAT IS INTENTIONAL (ref #2278):
//         scrollViewHeight is reset to 0 in two places:
//           1. onChange(of: willShowToken) — fires synchronously in onWillShow,
//              BEFORE MBK reads fittingSize and calls show(). This is the primary
//              reset and the one that actually prevents the wrong-height flash:
//              scrollViewHeight == 0 means .frame(height: nil) when fittingSize is
//              read, so MBK seeds contentSize from the unconstrained natural height.
//           2. onChange(of: isOpen) false branch — fires after the popover closes,
//              while no layout passes are active. Belt-and-suspenders: clears any
//              stale value written by post-close layout passes (e.g. settings→main
//              remount inside onWillClose teardown) so it cannot poison fittingSize
//              on a rapid reopen that fires before willShowToken is processed.
//         ORDERING: willShowToken always fires before isOpen flips to false
//         (willShowToken is bumped in onWillShow pre-show; isOpen is set in onDidShow
//         post-show, and cleared in onWillClose after that). The close-branch reset
//         therefore always fires AFTER the token reset for the same session —
//         the overlap is benign and both writes are idempotent.
//         ❌ NEVER remove either reset site without understanding this interaction.
//         ❌ NEVER add a reset in the isOpen=true open branch — that fires post-show
//            and causes a mid-session re-layout that churns width through MBK.
//
// NSApp.windows ITERATION IN isMenuBarHidden:
//         isMenuBarHidden iterates NSApp.windows to find the status-bar button window.
//         This is O(n) and involves AppKit synchronisation, but it is called only
//         from log() statements inside #if DEBUG guards and is compiled away entirely
//         in release builds. It MUST NOT be called from any non-debug layout or
//         rendering path.
//         ⚠️ TEMPORARY — remove after side-jump bug (#2265) is resolved.
//         ❌ NEVER call isMenuBarHidden from body, screenScrollMaxHeight, or any
//            computed var outside a #if DEBUG guard.
//
// NOTE ON LOGGING:
//         log() calls in this file use LogCategory.panel. They are intentionally
//         inside #if DEBUG guards — they capture geometry behaviour during the
//         side-jump investigation (#2265) and will be removed wholesale when that
//         issue is resolved. Do NOT remove them individually before then; removing
//         one log in isolation makes it harder to reconstruct the full sizing trace.
//         Remove all .panel logs in this file together when closing #2265.
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
    @Environment(AppState.self) private var appState
    /// View model for CPU/memory stats displayed in the header.
    @State private var systemStats = SystemStatsViewModel()
    /// Number of workflow rows currently shown in the actions section.
    @State private var visibleCount: Int = 10
    /// Increments every second to drive relative-time label refreshes without re-polling.
    @State private var displayTick: Int = 0
    /// Structured task driving the 1-second `displayTick` loop; managed by `startDisplayTickTimer()`.
    /// Named "displayTick" for visibility in Instruments (RG6).
    @State private var displayTickTask: Task<Void, any Error>?
    /// Height of the ScrollView frame, driven by the content GeometryReader (RULE 5).
    /// Starts at 0 (no constraint) until the first measurement fires on appear.
    ///
    /// Reset at two points — see DUAL scrollViewHeight RESET in the file header.
    @State private var scrollViewHeight: CGFloat = 0
    /// Measured natural height of PanelHeaderView. Captured once on appear (RULE 12).
    /// Used to subtract from the cap so the full panel never overflows the screen.
    @State private var headerHeight: CGFloat = 0

    /// Creates a `PanelMainView`.
    init(
        onStepTap: @escaping (ActiveJob, GitHubStep) -> Void,
        onSelectSettings: @escaping () -> Void
    ) {
        self.onStepTap = onStepTap
        self.onSelectSettings = onSelectSettings
    }

    /// Returns true when the status item button window is off-screen (menubar hidden).
    ///
    /// ⚠️ TEMPORARY — remove after side-jump bug (#2265) is resolved.
    /// ⚠️ DEBUG-ONLY — called exclusively from #if DEBUG log() blocks.
    /// Iterates NSApp.windows (O(n), AppKit-synchronised) to locate the status-bar
    /// button window. This cost is acceptable only because every call site is guarded
    /// by #if DEBUG and compiled away in release builds.
    /// ❌ NEVER call this from body, screenScrollMaxHeight, or any layout path
    ///    outside a #if DEBUG guard — it will add AppKit synchronisation to every
    ///    layout pass and cause measurable frame drops.
    private var isMenuBarHidden: Bool {
        for win in NSApp.windows {
            let typeName = String(describing: type(of: win))
            if typeName.contains("StatusBar") {
                let screenH = win.screen?.frame.height ?? -1
                return screenH < 0 || win.frame.maxY > screenH
            }
        }
        return false
    }

    /// Maximum height for the scroll section.
    /// = `AppDelegate.panelHeightMultiplier` × visibleFrame.height − headerHeight.
    /// This ensures the full panel (header + divider + scroll) stays within the cap.
    /// ❌ MUST use AppDelegate.panelHeightMultiplier — never inline the value here.
    ///    See RULE 11 / CAP ALIGNMENT in the file header.
    /// ❌ NEVER use fixed pixel values here. headerHeight is content-derived (RULE 12).
    /// ❌ NEVER call isMenuBarHidden here outside #if DEBUG — it iterates NSApp.windows.
    private var screenScrollMaxHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let cap = visibleHeight * AppDelegate.panelHeightMultiplier - headerHeight
        #if DEBUG
        log(
            "【PanelMainView.screenScrollMaxHeight】" +
            "visibleHeight=\(visibleHeight) headerHeight=\(headerHeight) cap=\(cap) multiplier=\(AppDelegate.panelHeightMultiplier) menuBarHidden=\(isMenuBarHidden)",
            category: .panel
        )
        #endif
        return cap
    }

    /// Root body -- header, optional error/rate-limit banners, local runner rows, and the scrollable actions section.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeaderView(
                statsVM: systemStats,
                onSelectSettings: onSelectSettings
            )
            // RULE 10: LOAD-BEARING — do not remove or change to fixedSize(horizontal:vertical:).
            // See RULE 10 in the file header for the full explanation of why both axes are needed.
            .fixedSize()
            // Header GeometryReader (RULE 12).
            // Lives in .background() so it measures without influencing layout.
            // Writes headerHeight once on appear; updates only if the header truly changes.
            // See MULTIPLE GEOMETRYREADERS in the file header for why this is separate
            // from the content and scroll GRs below.
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear {
                            #if DEBUG
                            let prev = headerHeight
                            #endif
                            headerHeight = geo.size.height
                            #if DEBUG
                            log("【header.geo】onAppear h=\(geo.size.height) menuBarHidden=\(isMenuBarHidden) (was \(prev))", category: .panel)
                            #endif
                        }
                        .onChange(of: geo.size.height) { _, newH in
                            #if DEBUG
                            let prev = headerHeight
                            #endif
                            headerHeight = newH
                            #if DEBUG
                            log("【header.geo】onChange \(prev) → \(newH) menuBarHidden=\(isMenuBarHidden) ← HEADER HEIGHT CHANGED", category: .panel)
                            #endif
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
            // Color.clear trigger for localRunnerStore.refresh() on appear.
            // Zero-size so it has no visual presence or layout impact.
            Color.clear.frame(width: 0, height: 0)
                .onAppear {
                    Task { await localRunnerStore.refresh() }
                }
            actionsSectionScrollable
        }
        // RULE 1: LOAD-BEARING — do not remove or change to fixedSize(horizontal:vertical:).
        // See RULE 1 in the file header for the full explanation of why both axes are needed.
        .fixedSize()
        // Root VStack GeometryReader — debug logging only, writes no state.
        // Lives in .background() so it cannot influence the size it measures.
        // See MULTIPLE GEOMETRYREADERS in the file header.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        #if DEBUG
                        log("【rootVStack.geo】onAppear size=\(geo.size) menuBarHidden=\(isMenuBarHidden)", category: .panel)
                        #endif
                    }
                    .onChange(of: geo.size) { _, newSize in
                        #if DEBUG
                        log("【rootVStack.geo】onChange → \(newSize) menuBarHidden=\(isMenuBarHidden)", category: .panel)
                        #endif
                    }
            }
        )
        .onAppear {
            #if DEBUG
            log("【PanelMainView】onAppear panelOpen=\(panelVisibilityState.isOpen) menuBarHidden=\(isMenuBarHidden)", category: .panel)
            #endif
            if panelVisibilityState.isOpen { systemStats.start() }
            startDisplayTickTimer()
        }
        .onDisappear {
            #if DEBUG
            log("【PanelMainView】onDisappear menuBarHidden=\(isMenuBarHidden)", category: .panel)
            #endif
            systemStats.stop()
            stopDisplayTickTimer()
        }
        // PRIMARY scrollViewHeight reset — see DUAL scrollViewHeight RESET in file header.
        // Fires synchronously in onWillShow, before MBK reads fittingSize and calls show(),
        // so the stale height is gone before contentSize is seeded.
        // ❌ NEVER remove. ❌ NEVER move to onChange(of: isOpen) open branch (too late).
        .onChange(of: panelVisibilityState.willShowToken) { _, _ in
            #if DEBUG
            log("【PanelMainView】willShowToken fired — resetting scrollViewHeight menuBarHidden=\(isMenuBarHidden)", category: .panel)
            #endif
            scrollViewHeight = 0
        }
        .onChange(of: panelVisibilityState.isOpen) { _, newOpen in
            #if DEBUG
            log("【PanelMainView】panelVisibilityState.isOpen → \(newOpen) menuBarHidden=\(isMenuBarHidden)", category: .panel)
            #endif
            if newOpen {
                // scrollViewHeight was already reset to 0 in the close branch below,
                // so the > 0 ? ... : nil guard in actionsSectionScrollable handles the
                // first layout pass unconstrained. Do NOT reset here — resetting at
                // open time causes a mid-session re-layout that churns the reported
                // width through MBKPopoverController, triggering spurious
                // WRITE+REANCHOR calls that jump the header. See #2279.
                systemStats.start()
            } else {
                // SECONDARY scrollViewHeight reset — see DUAL scrollViewHeight RESET in file header.
                // Belt-and-suspenders: clears any stale value written by post-close layout
                // passes so it cannot poison fittingSize on a rapid reopen. The willShowToken
                // reset (above) is the authoritative guard; this one fires after close and
                // is redundant for normal flows. Both are idempotent. ❌ NEVER remove.
                scrollViewHeight = 0
                systemStats.stop()
            }
        }
        // Reset the visible row count only when the list shrinks (e.g. a runner is removed),
        // not on every poll update — avoids snapping the user back mid-scroll.
        .onChange(of: appState.runnerState.actions) { oldActions, newActions in
            #if DEBUG
            log("【PanelMainView】actions count → \(newActions.count) menuBarHidden=\(isMenuBarHidden)", category: .panel)
            #endif
            if newActions.count < oldActions.count { visibleCount = 10 }
        }
    }

    // MARK: - Scroll section

    /// Scrollable container for the actions section.
    /// Height is driven by a content GeometryReader into `scrollViewHeight`,
    /// capped at `screenScrollMaxHeight` (see RULE 5).
    ///
    /// WHY .frame(height: scrollViewHeight > 0 ? scrollViewHeight : nil):
    /// See WHY .frame(height:) NOT maxHeight in the file header. The `> 0` guard
    /// keeps the constraint absent on the first layout pass so SwiftUI can measure
    /// the content unconstrained before we lock in the height.
    private var actionsSectionScrollable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            actionsSectionContent
                // RULE 5: LOAD-BEARING — forces natural height measurement before ScrollView clips.
                .fixedSize(horizontal: false, vertical: true)
                // Content GeometryReader (RULE 5).
                // Writes scrollViewHeight. Lives in .background() so it measures
                // without influencing the content height it is capturing.
                // See MULTIPLE GEOMETRYREADERS in the file header.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                let cap = screenScrollMaxHeight
                                let capped = min(geo.size.height, cap)
                                #if DEBUG
                                log(
                                    "【scrollContent.geo】onAppear raw=\(geo.size.height) cap=\(cap)" +
                                    " capped=\(capped) scrollViewHeight=\(scrollViewHeight) menuBarHidden=\(isMenuBarHidden)",
                                    category: .panel
                                )
                                #endif
                                scrollViewHeight = capped
                                #if DEBUG
                                log("【scrollContent.geo】scrollViewHeight SET → \(scrollViewHeight)", category: .panel)
                                #endif
                            }
                            .onChange(of: geo.size.height) { _, newH in
                                let cap = screenScrollMaxHeight
                                let capped = min(newH, cap)
                                #if DEBUG
                                log(
                                    "【scrollContent.geo】onChange raw → \(newH) cap=\(cap)" +
                                    " capped=\(capped) scrollViewHeight was=\(scrollViewHeight) menuBarHidden=\(isMenuBarHidden)",
                                    category: .panel
                                )
                                #endif
                                scrollViewHeight = capped
                                #if DEBUG
                                log("【scrollContent.geo】scrollViewHeight SET → \(scrollViewHeight)", category: .panel)
                                #endif
                            }
                    }
                )
        }
        // See WHY .frame(height:) NOT maxHeight in the file header.
        .frame(height: scrollViewHeight > 0 ? scrollViewHeight : nil)
        // ScrollView GeometryReader — debug logging only, writes no state.
        // See MULTIPLE GEOMETRYREADERS in the file header.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        #if DEBUG
                        log("【scrollView.geo】onAppear h=\(geo.size.height) menuBarHidden=\(isMenuBarHidden)", category: .panel)
                        #endif
                    }
                    .onChange(of: geo.size.height) { _, newH in
                        #if DEBUG
                        log("【scrollView.geo】onChange → \(newH) menuBarHidden=\(isMenuBarHidden)", category: .panel)
                        #endif
                    }
            }
        )
    }

    // MARK: - Display tick timer

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
}
