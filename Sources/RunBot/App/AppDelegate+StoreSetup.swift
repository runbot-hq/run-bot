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
    /// 1. Hydrate `ScopeEntry.displayName` from persisted prefs (must precede UI).
    /// 2. `setupStatusItem()` / `setupPanel()` — UI wiring only, no domain calls.
    /// 3. `appState.start(onUpdateStatusIcon:)` — domain startup sequence:
    ///    `LocalRunnerStore.configure` → `refreshAsync` → poll loop →
    ///    update check → background scheduler → status-icon + sign-out tasks.
    ///
    /// - Parameter _: The notification (unused).
    func applicationDidFinishLaunching(_ _: Notification) {
        log("AppDelegate › applicationDidFinishLaunching — START")

        let knownScopes = ScopeStore.shared.entries.map(\.scope)
        log("AppDelegate › applicationDidFinishLaunching — startup task for \(knownScopes.count) scopes")

        Task {
            // Hydrate display names before any UI or domain work. (#1538)
            await ScopeStore.shared.refreshDisplayNames()

            // UI wiring — no domain calls here.
            setupStatusItem()
            setupPanel()

            // Domain startup — fully owned by AppState.
            // `updateStatusIcon` is an AppDelegate method (AppKit concern) passed
            // as a callback so AppState never imports AppKit or holds AppDelegate.
            await appState.start(onUpdateStatusIcon: { [weak self] in
                self?.updateStatusIcon()
            })

            log("AppDelegate › applicationDidFinishLaunching — DONE")
        }
    }
}
