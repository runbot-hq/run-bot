// SettingsDependencies.swift
// RunBot

import AppUpdater
import RunBotCore

// MARK: - SettingsDependencies

/// Holds the services genuinely needed by the windowed Settings destination.
///
/// Owned once by `AppDependencies` and threaded through
/// `AppNavigationSplitView` → `AppDetailColumnView` → `SettingsListView`.
/// Do not instantiate services inside this type — receive them from
/// the composition root to avoid the startup-coupling regression
/// removed after issue #2815.
///
/// ## Auth actions
/// OAuth sign-in / sign-out require `OAuthCredentialController`, which
/// depends on `GitHubClient`. Rather than pulling `GitHubClient` into
/// this layer, those actions are expressed as plain closures built
/// at the app root where the controller already exists.
@MainActor
final class SettingsDependencies {
    /// App-wide preference store (automatic updates, beta channel).
    let settings: AppPreferencesStore
    /// Observable runner state — drives the update action row.
    let runnerState: RunnerState
    /// Shared auto-updater; must be owned at the composition root.
    let autoUpdater: AppUpdater
    /// Notification delivery preferences; must use `NotificationPreferences.shared`
    /// so the poller and Settings picker read the same object.
    let notifications: NotificationPreferences

    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: @MainActor () -> Void
    /// Called to sign out and remove the stored OAuth token.
    let onSignOut: @MainActor () async -> Void
    /// Runs environment-token discovery and OAuth-state sync so the
    /// Authentication card exits `.checking` when it mounts.
    /// Must use the same `GitHubAuthentication` and `GitHubClient`
    /// instances already owned by the dependency graph.
    let refreshAuthentication: @MainActor () async -> Void

    /// Creates a fully configured settings dependency bundle.
    init(
        settings: AppPreferencesStore,
        runnerState: RunnerState,
        autoUpdater: AppUpdater,
        notifications: NotificationPreferences,
        onSignIn: @escaping @MainActor () -> Void,
        onSignOut: @escaping @MainActor () async -> Void,
        refreshAuthentication: @escaping @MainActor () async -> Void
    ) {
        self.settings = settings
        self.runnerState = runnerState
        self.autoUpdater = autoUpdater
        self.notifications = notifications
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
        self.refreshAuthentication = refreshAuthentication
    }
}
