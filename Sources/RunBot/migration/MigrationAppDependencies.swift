// MigrationAppDependencies.swift
// RunBot

import AppKit
import AppUpdater
import GitHubClient
import Observation
import RunBotCore

// MARK: - MigrationAppDependencies

/// Thin adapter around `AppState` for the windowed migration app shell.
///
/// Instead of constructing its own `RunnerState`, `RunnerPoller`, `GitHubClient`,
/// or credential controller, this type forwards all domain state from the single
/// `AppState` instance that the main app uses. This ensures the windowed app and
/// the menu-bar panel observe the same `RunnerState` — when the poller publishes
/// a completed snapshot, all views invalidate reactively without manual refresh,
/// reselection, or status aggregation.
///
/// Startup ordering (mirrors `AppDelegate+StoreSetup.swift`):
///   LocalRunnerStore.configure    <- synchronous, before start()
///   appState.start                <- async, owned by the caller
@MainActor
@Observable
final class MigrationAppDependencies {

    /// The single `AppState` instance shared with the main app's menu-bar panel.
    let appState: AppState

    /// Observable runner state forwarded from `appState`.
    var runnerState: RunnerState { appState.runnerState }

    /// Configured local-runner store captured at init time.
    /// Captured from `LocalRunnerStore.shared` after `configure()` is called
    /// synchronously in `RunBotDesktopApp.init()`. This avoids reading `AppState`'s
    /// not-yet-seeded private `_localRunnerStore` during SwiftUI body construction.
    let localRunnerStore: LocalRunnerStore

    /// Dependencies for the Settings scene (accounts, preferences, scopes).
    let settingsDependencies: MigrationSettingsDependencies

    /// Creates the adapter and constructs settings dependencies from `AppState`.
    /// - Parameters:
    ///   - appState: The single `AppState` instance owned by the process.
    ///   - localRunnerStore: The already-configured `LocalRunnerStore` singleton.
    init(appState: AppState, localRunnerStore: LocalRunnerStore) {
        self.appState = appState
        self.localRunnerStore = localRunnerStore

        // Build settings dependencies from AppState's services.
        self.settingsDependencies = MigrationSettingsDependencies(
            settings: .shared,
            runnerState: appState.runnerState,
            autoUpdater: appState.autoUpdater,
            onSignIn: { [appState] in
                guard let url = appState.oauthCredentials.makeSignInURL() else {
                    log("MigrationAppDependencies › makeSignInURL returned nil")
                    return
                }
                NSWorkspace.shared.open(url)
            },
            onSignOut: { [appState] in
                await appState.oauthCredentials.signOut()
            }
        )
    }
}

// MARK: - Startup

/// Startup lifecycle for `MigrationAppDependencies`.
extension MigrationAppDependencies {
    /// Starts the domain pipeline by delegating to `AppState.start()`.
    ///
    /// The windowed app has no status icon, so a no-op closure is passed for
    /// `onUpdateStatusIcon`. All other startup behaviour (credential reconcile,
    /// local runner hydration, poll loop, update check) is identical to the
    /// main app's startup sequence.
    func start() async {
        await appState.start(onUpdateStatusIcon: {})
    }

    /// Triggers a poll-loop restart via `AppState.refreshOnPanelShow()`.
    func refresh() async {
        await appState.refreshOnPanelShow()
    }
}
