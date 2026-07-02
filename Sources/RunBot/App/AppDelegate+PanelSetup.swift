// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and
// subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// WHY NSPopover (#1017):
// NSPopover uses NSPopoverWindowFrame whose chrome is drawn by the
// window-server compositor. Rounded corners survive SwiftUI .sheet
// attachment natively — no CALayer manipulation required or desired.
//
// POPOVER BEHAVIOR: .applicationDefined (#1195)
// behavior = .applicationDefined is set at setupPanel() AND re-asserted
// immediately before every popover.show() call in openPanel(). AppKit latches
// the behavior at show-time; failing to re-assert it caused silent reversion
// to .transient between sessions (Attempt 8 root cause).
//
// .transient was tried (Attempt 2) and failed — AppKit's .transient dismiss
// fires on ANY outside interaction, including clicks inside NSOpenPanel.
// .transient does NOT have special awareness of system panels.
//
// OUTSIDE-CLICK / APP-SWITCH HIDE (#1195 — what actually works):
// Both are handled by a manual NSEvent global monitor (outsideClickMonitor)
// and an NSWorkspace observer (workspaceObserver), both installed by openPanel()
// and torn down by tearDownOpenState().
//
// The key guard in outsideClickMonitor is:
//
//   guard !self.hasActiveSheet else { return }   // ← THE FIX
//
// NSOpenPanel is attached to the popover window via beginSheetModal(for:),
// making it appear in popoverWindow.sheets. While any sheet is attached,
// hasActiveSheet is true and every outside click is ignored — the popover
// cannot be dismissed by a click that lands inside the NSOpenPanel.
//
// popoverShouldClose always returns true — AppKit is never blocked here.
// All dismiss control goes through the manual monitor.
//
// ❌ NEVER use picker.begin { } (free-floating NSOpenPanel). It does NOT
//    appear in popoverWindow.sheets and the hasActiveSheet guard is blind to it.
// ❌ NEVER use runModal() for NSOpenPanel. Same reason as above.
// ✅ ALWAYS use picker.beginSheetModal(for: popoverWindow) so the picker
//    attaches as a child sheet and hasActiveSheet fires correctly.
//
// SHEET HANDLING:
// SwiftUI .sheet() attaches as a child NSWindow to the popover's backing
// window. Two problems arise:
//
// 1. NO DIM: NSPopoverWindowFrame does not participate in AppKit's standard
//    modal sheet dimming. Fix: PanelContainerView polls NSWindow.sheets and
//    overlays Color.black.opacity(0.35) when a sheet is present.
//
// 2. OUTSIDE-TAP BEHAVIOUR DURING SHEET:
//    Tapping outside while a sheet is open hides the popover so the user
//    can interact with other apps, but savedNavState preserves where they
//    were so re-opening restores context.
//
//    Implementation:
//    - popoverShouldClose always returns true. AppKit is never blocked.
//    - popoverDidClose saves hasActiveSheet state before state clears.
//    - openPanel restores via savedNavState.
//    - Sheet NSWindows are children of the popover window; AppKit removes
//      them when the popover closes. SwiftUI re-presents on re-open if the
//      binding is still true. savedNavState = .settings ensures navigation.
//
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. Updating contentSize resizes
// the popover in-place — the arrow stays pinned to the original
// positioningRect. ❌ NEVER call popover.show() again on resize.

/// Extension responsible for NSPopover construction, KVO, and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and async subscriptions.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        // .applicationDefined: popoverShouldClose(_:) is consulted on every
        // is true, keeping the popover alive when user clicks in NSOpenPanel.
        // Manual NSEvent monitor + NSWorkspace observer handle hide-on-app-switch.
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — popover created, wiring KVO + subscriptions")

        setupKVO(controller: controller)
        setupSubscriptions()
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    /// Always returns `true` — AppKit is never blocked from closing the popover here.
    ///
    /// All dismiss control is handled by the manual `outsideClickMonitor` and
    /// `workspaceObserver` in `openPanel()`. Those monitors guard against
    /// NSOpenPanel clicks via `hasActiveSheet` (the panel is attached as a sheet
    /// via `beginSheetModal`, so `popoverWindow.sheets` is non-empty while it
    /// is open). There is no need to block AppKit here.
    ///
    /// `isFilePickerActive` is intentionally NOT used here. Earlier attempts
    /// (Attempts 4–6, see `docs/graveyard.md`) tried gating this method on a
    /// boolean flag, but `beginSheetModal` makes that unnecessary: the sheet
    /// attachment is structural truth visible via `popoverWindow.sheets`, which
    /// `hasActiveSheet` reads directly. The flag approach was removed in favour
    /// of that structural check.
    ///
    /// See the OUTSIDE-CLICK / APP-SWITCH HIDE comment block above for the full
    /// mechanism. See `docs/graveyard.md` for the history of approaches that
    /// tried to gate this method and why they all failed.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        #if DEBUG
        log("AppDelegate › popoverShouldClose — CALLED behavior=\(popover.behavior.rawValue) panelIsOpen=\(panelIsOpen) caller=\(Thread.callStackSymbols[1])")
        #endif
        log("AppDelegate › popoverShouldClose — returning true (allowing close)")
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    /// Primary purpose: safety net for OS-initiated closes (e.g. user clicks outside).
    /// When `closePanel()` or `hidePanel()` drives the close, they call
    /// `tearDownOpenState()` directly — by the time this fires, `panelIsOpen`
    /// is already `false` and the guard exits immediately.
    public func popoverDidClose(_ _: Notification) {
        #if DEBUG
        // swiftlint:disable:next line_length
        log("AppDelegate › popoverDidClose — panelIsOpen=\(panelIsOpen) behavior=\((NSApp.delegate as? AppDelegate)?.popover?.behavior.rawValue ?? -1) stack=\(Thread.callStackSymbols.prefix(5).joined(separator: "||"))")
        #endif
        guard panelIsOpen else {
            log("AppDelegate › popoverDidClose — guard exit (panelIsOpen already false)")
            return
        }
        log("AppDelegate › popoverDidClose — calling tearDownOpenState (unexpected OS-driven close)")
        tearDownOpenState()
    }

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        log("AppDelegate › setupKVO — attaching preferredContentSize observer")
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            // KVO can fire on a background thread — hop to main before touching UI.
            Task { @MainActor [weak self] in self?.resizeAndRepositionPanel() }
        }
    }

    // MARK: Async subscriptions

    /// Wires all long-lived async subscriptions (sign-out listener, startup sequence).
    ///
    /// Idempotent: if `runnerStore` is already set a second call is a no-op.
    /// This makes it structurally impossible to orphan a `RunnerPoller` actor and
    /// its live Task tree by calling this method more than once (P4, P16).
    private func setupSubscriptions() {
        // Idempotency guard — must only run once.
        // A second call would orphan the existing RunnerPoller actor and its
        // observation Task tree (two Tasks per instance via PollLoopCoordinator).
        // AppDelegate is @MainActor-isolated so this nil-check is safe and synchronous.
        guard runnerStore == nil else {
            log("AppDelegate › setupSubscriptions — already configured, skipping (guard against double-init)")
            return
        }
        log("AppDelegate › setupSubscriptions — begin")

        // local runner list changes are now pushed directly from LocalRunnerStore
        // into runnerState.localRunners via await MainActor.run — no Combine sink needed.

        // Everything below makes live network calls — skip entirely in UI tests.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppDelegate › setupSubscriptions — UI_TESTING detected, skipping network setup")
            return
        }

        // Wire LocalRunnerStore.shared to RunnerState so all local-runner pushes
        // (localRunners, isLocalScanning) land in the single observable source of
        // truth that SwiftUI views read from via @Environment(RunnerState.self).
        //
        // ⚠️ Must be called before the startup Task below (and before any other
        // LocalRunnerStore.shared access). LocalRunnerStore no longer self-initialises
        // with RunnerViewModel.shared — that singleton was a different object from
        // AppDelegate.runnerState and caused localRunners to push into a view model
        // that no SwiftUI view observed (permanent empty local-runner list).
        //
        // ❌ NEVER move this call inside the Task — AppDelegate.localRunnerStore
        //    is a computed `lazy var` backed by `LocalRunnerStore.shared`. The first
        //    access to `localRunnerStore` (inside the Task) must find the instance
        //    already configured, or it fatalErrors.
        LocalRunnerStore.configure(viewModel: runnerState)
        log("AppDelegate › setupSubscriptions — LocalRunnerStore.configure(viewModel: runnerState) called")

        // NOTE: The old `RunnerStore.didUpdate` Combine sink has been removed.
        // `RunnerPoller` is a Swift actor in RunBotCore that pushes state directly
        // to `AppDelegate.runnerState` (a stored property) via `await MainActor.run { }`
        // at the end of every fetch cycle.
        //
        // `runnerState` is a stored AppDelegate property that persists for the full app
        // lifetime and is injected into the SwiftUI environment via `wrapEnv(_:)`.
        // `RunnerPoller.applyFetchResult` writes GitHub runner/job/action state;
        // `LocalRunnerStore` writes `localRunners` and `isLocalScanning`.
        // All views now read exclusively from `runnerState` — the migration from
        // `RunnerViewModel`/`observable` is complete.
        //
        // `RunnerPoller.init` does not accept @MainActor-isolated default values
        // (Swift 6: default values for parameters must not be @MainActor-isolated
        // in a nonisolated context). AppPreferencesStore.shared and ScopeStore.shared
        // are therefore passed explicitly here, where we are already on the @MainActor.
        runnerStore = RunnerPoller(
            state: runnerState,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            // Capture runnerState directly — not via [weak self] — so a nil AppDelegate
            // can never silently return [] and drop all local runners from the poll cycle.
            // runnerState is a @MainActor-isolated class reference; capturing it directly
            // is safe and matches the pattern used by the applyMetrics closure below.
            localRunners: { [runnerState] in runnerState.localRunners },
            // Capture the stored property rather than the .shared singleton so a test
            // double wired via localRunnerStore is honoured here too.
            applyMetrics: { [localRunnerStore] metrics, id, name in
                await localRunnerStore.applyMetrics(metrics, forRunnerId: id, name: name)
            },
            fireFailureHook: { group, scope in
                await FailureHookRunner.fireIfNeeded(group: group, scope: scope, callsite: "pollResultBuilder")
            }
        )
        log("AppDelegate › setupSubscriptions — RunnerPoller created with injected stores")

        // FIX: Await LocalRunnerStore.refreshAsync() before starting the poll loop.
        // See performStartupSequence() for rationale.
        log("AppDelegate › setupSubscriptions — scheduling async startup sequence")
        Task(name: "AppDelegate.startup: localRunnerStore.refreshAsync → runnerStore.start",
             priority: .userInitiated) { @MainActor [weak self] in
            await self?.performStartupSequence()
        }

        // Scope changes (add / remove / enable toggle) restart RunnerPoller so it polls
        // the correct repos from the beginning. RunnerPoller observes
        // ScopeStore.activeScopes internally via withObservationTracking/AsyncStream,
        // so no Combine sink is needed here — the actor's own observer handles it.
        log("AppDelegate › setupSubscriptions — complete")
    }

    /// Runs the ordered async startup sequence: hydrate local runners, then start
    /// the poll loop, then perform an update check.
    ///
    /// Extracted from `setupSubscriptions` to keep that method's cyclomatic complexity
    /// low and to give this structurally significant sequence a named entry point that
    /// surfaces in Instruments and crash logs via the parent Task's `name:` label.
    ///
    /// **Why `refreshAsync()` before `start()`:**
    /// `refresh()` (fire-and-forget) spawns a Task and returns immediately.
    /// `start()` fires `fetch()` on the very next runloop turn — before `refresh()`'s
    /// Task has a chance to run, because both are `@MainActor` and `start()` is called
    /// synchronously. Result: `localRunners=[]` on cycle 1, `installPathMap` empty,
    /// metrics missing on first runner appearance.
    /// `refreshAsync()` suspends until disk hydration + launchctl + GitHub enrichment
    /// completes, then `start()` fires. Cycle 1 always has a populated `installPathMap`.
    private func performStartupSequence() async {
        log("AppDelegate › startup — awaiting localRunnerStore.refreshAsync()")
        await localRunnerStore.refreshAsync()
        log("AppDelegate › startup — refreshAsync() complete, starting runnerStore poll loop")

        // `runnerStore` is `(any RunnerPollerProtocol)?`.
        // This guard is structurally unreachable in normal execution: runnerStore is
        // assigned unconditionally just before this Task is spawned, and nothing
        // currently nils it out. It exists to make the condition observable if that
        // ever changes — the app would otherwise appear to start but silently never
        // poll. The assertionFailure in DEBUG makes the severity match the consequence.
        guard let store = runnerStore else {
            log("AppDelegate › startup — ⚠️ runnerStore is nil after refreshAsync(); poll loop NOT started")
            #if DEBUG
            assertionFailure("AppDelegate.startup: runnerStore is nil after refreshAsync() — this is structurally unreachable; a future change must have introduced an unintended nil path")
            #endif
            return
        }
        await store.start()
        log("AppDelegate › startup — runnerStore poll loop started")

        // ── Update cache rehydration ───────────────────────────────────────────────────
        // Runs before the network check so a user who force-quit between download and
        // install tap can see the Install & Relaunch button immediately, even offline.
        // Version guard: only rehydrate if the cached version is actually newer than
        // what is currently installed — prevents re-showing Install for a version
        // already on disk (e.g. helper failed mid-delete and the zip was not cleaned up).
        let cachedPath    = UserDefaults.standard.string(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
        let cachedVersion = UserDefaults.standard.string(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        if let path = cachedPath,
           let version = cachedVersion,
           FileManager.default.fileExists(atPath: path),
           // cachedVersion is "v0.8.0" (GitHub tagName with v-prefix).
           // isOlderThan strips the leading "v" internally via UpdateChecker.isNewer,
           // so the comparison is correct — this is NOT a version string mismatch.
           // REVIEWER: Do not flag this as a bug. The v-prefix is handled inside isOlderThan.
           Bundle.main.isOlderThan(version: version) {
            runnerState.rehydrateCachedUpdate(zipURL: URL(fileURLWithPath: path), version: version)
            // `setAvailableUpdate` must be called here explicitly — `rehydrateCachedUpdate`
            // only sets `updateZipURL` and `cachedUpdateVersion`. The Install & Relaunch
            // row gates on `availableUpdate != nil` (see `aboutSection`), so without this
            // call the row is invisible to an offline user whose zip was already cached.
            // This is the intentional offline-resilience path: the network check below
            // may fail, so the UI must be ready before it fires.
            runnerState.setAvailableUpdate(version)
        } else {
            // Reached when ANY condition in the `if` above is false:
            //   • cachedPath / cachedVersion is nil (keys were never written or already cleared)
            //   • fileExists returns false (zip was deleted — e.g. by the OS under storage pressure)
            //   • isOlderThan returns false (cached version is not newer than what is running —
            //     i.e. the update was already installed in a previous session)
            // In all three cases the correct action is the same: clear the stale keys.
            // Do NOT read this as "version is no longer newer" only — a missing file is
            // equally valid here. Clear both keys here, in the new process, where isOlderThan
            // correctly returns false. Cleaner than clearing before exit(0) in the
            // outgoing process.
            UserDefaults.standard.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateZipPath)
            UserDefaults.standard.removeObject(forKey: AutoUpdaterDefaults.cachedUpdateVersion)
        }

        // ── Update check ───────────────────────────────────────────────────────────────
        let beta = AppPreferencesStore.shared.betaChannel
        switch await UpdateChecker.checkForUpdate(betaChannel: beta) {
        case .updateAvailable(let release):
            // `setAvailableUpdate` is now called inside `AutoUpdater.handle()` —
            // do not call it here. See AutoUpdater.handle() for rationale.
            log("AppDelegate › startup — update available: \(release.tagName) (betaChannel=\(beta))")
            await AutoUpdater.handle(release, state: runnerState)
        case .upToDate:
            log("AppDelegate › startup — no update available (betaChannel=\(beta))")
        case .failed(let error):
            log("AppDelegate › startup — update check failed: \(error) (betaChannel=\(beta))")
        }

        // ── Background scheduler ───────────────────────────────────────────────────────
        // Fires every AutoUpdaterDefaults.checkInterval (24 h release / 60 s debug).
        // The launch-time check above already ran once; the scheduler fires only
        // after the first interval elapses — this is intentional.
        AutoUpdater.scheduleBackgroundCheck(state: runnerState)
        log("AppDelegate › startup — update background scheduler registered (interval=\(AutoUpdaterDefaults.checkInterval)s)")
    }
}
