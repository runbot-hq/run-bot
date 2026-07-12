// AppDelegate+StoreSetup.swift
// RunBot

import AppKit
import RunBotCore

/// AppDelegate extension wiring app-lifecycle callbacks to store and service setup.
extension AppDelegate {

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    /// - Parameter _: The notification (unused).
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Builds the status-bar item and NSPopover panel,
    /// then delegates the full domain startup sequence to `appState.start()`.
    ///
    /// ## Startup ordering
    /// 1. `LocalRunnerStore.configure(viewModel:)` — MUST be the very first call,
    ///    synchronously before any `await`. Any `@MainActor` work enqueued during
    ///    a suspension point that reaches `LocalRunnerStore.shared` before configure
    ///    runs will hit a `fatalError`. Fix for issue #1741 — do not move this down.
    /// 2. Hydrate `ScopeEntry.displayName` from persisted prefs.
    /// 3. `setupStatusItem()` / `setupPanel()` — UI wiring only, no domain calls.
    /// 4. `appState.start(onUpdateStatusIcon:)` — remaining domain startup:
    ///    `refreshAsync` → poll loop → update check → background scheduler →
    ///    status-icon + sign-out tasks.
    ///
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")

        // ⚠️ MUST be synchronous and before the first await — see ordering rule 1 above.
        // Fixes issue #1741: any indirect LocalRunnerStore.shared access during the
        // refreshDisplayNames() suspension window would hit the fatalError guard
        // if configure() had not already been called.
        LocalRunnerStore.configure(viewModel: appState.runnerState)
        log("AppDelegate › applicationDidFinishLaunching — LocalRunnerStore configured")

        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        log("AppDelegate › applicationDidFinishLaunching — startup task for \(knownScopes.count) scopes")

        Task {
            // Hydrate display names before any UI or domain work. (#1538)
            await ScopeStore.shared.refreshDisplayNames()

            // UI wiring — no domain calls here.
            setupStatusItem()
            setupPanel()

            // Domain startup — fully owned by AppState.
            // configure() has already been called above; appState.start() assumes this.
            // `updateStatusIcon` is an AppDelegate method (AppKit concern) passed
            // as a callback so AppState never imports AppKit or holds AppDelegate.
            //
            // Startup ordering safety: appState.start() suspends on refreshAsync()
            // (Step 3) before it calls store.start() (Step 4). That suspension yields
            // back to this Task's outer continuation, but by that point setupStatusItem()
            // and setupPanel() have already completed above. The status-icon and
            // sign-out observation tasks (Step 7) are started after store.start(),
            // so they can never fire before the poll loop is running.
            await appState.start(onUpdateStatusIcon: { [weak self] in
                self?.updateStatusIcon()
            })

            log("AppDelegate › applicationDidFinishLaunching — DONE")
        }
    }
}
