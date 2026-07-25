// AppDelegate+StoreSetup.swift
// RunBot

import AppKit
import RunBotCore

/// AppDelegate extension wiring app-lifecycle callbacks to store and service setup.
extension AppDelegate {

    // MARK: - App lifecycle

    /// Sets activation policy during UI tests so XCTest can see windows.
    func applicationWillFinishLaunching(_ _: Notification) {
        guard ProcessInfo.processInfo.environment["UI_TESTING"] != nil else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Entry point after launch. Builds the panel, then delegates the full domain
    /// startup sequence to `appState.start()`.
    ///
    /// ## Startup ordering
    /// 1. `LocalRunnerStore.configure(viewModel:)` — MUST be the very first call,
    ///    synchronously before any `await`. Any `@MainActor` work enqueued during
    ///    a suspension point that reaches `LocalRunnerStore.shared` before configure
    ///    runs will hit a `fatalError`. Fix for issue #1741 — do not move this down.
    /// 2. Hydrate `ScopeEntry.displayName` from persisted prefs.
    /// 3. `setupPanel()` — creates MBKPopoverController (which internally creates
    ///    NSStatusItem + NSPopover). UI wiring only, no domain calls.
    /// 4. `appState.start(onUpdateStatusIcon:)` — remaining domain startup.
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")

        // ⚠️ MUST be synchronous and before the first await — see ordering rule 1 above.
        LocalRunnerStore.configure(viewModel: appState.runnerState)
        log("AppDelegate › applicationDidFinishLaunching — LocalRunnerStore configured")

        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        log("AppDelegate › applicationDidFinishLaunching — startup task for \(knownScopes.count) scopes")

        Task {
            await ScopeStore.shared.refreshDisplayNames()

            // setupPanel() creates MBKPopoverController which calls setup() internally,
            // creating NSStatusItem + NSPopover. No separate setupStatusItem() call needed.
            setupPanel()

            await appState.start(onUpdateStatusIcon: { [weak self] in
                self?.updateStatusIcon()
            })

            log("AppDelegate › applicationDidFinishLaunching — DONE")
        }
    }
}
