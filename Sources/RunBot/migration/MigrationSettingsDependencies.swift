// MigrationSettingsDependencies.swift
// RunBot

import AppUpdater
import RunBotCore

// MARK: - MigrationSettingsDependencies

/// Holds the services genuinely needed by the windowed Settings destination.
///
/// Owned once by `MigrationAppDependencies` and threaded through
/// `AppShellView` → `AppDetailView` → `MigrationSettingsView`.
/// Do not instantiate services inside this type — receive them from
/// the composition root to avoid the startup-coupling regression
/// removed after issue #2815.
///
/// ## Auth actions
/// OAuth sign-in / sign-out require `OAuthCredentialController`, which
/// depends on `GitHubClient`. Rather than pulling `GitHubClient` into the
/// migration layer, those actions are expressed as plain closures built
/// at the app root where the controller already exists.
@MainActor
final class MigrationSettingsDependencies {
    /// App-wide preference store (automatic updates, beta channel).
    let settings: AppPreferencesStore
    /// Observable runner state — drives the update action row.
    let runnerState: RunnerState
    /// Shared auto-updater; must be owned at the composition root.
    let autoUpdater: AppUpdater

    /// Called to initiate the OAuth sign-in browser flow.
    let onSignIn: @MainActor () -> Void
    /// Called to sign out and remove the stored OAuth token.
    let onSignOut: @MainActor () async -> Void

    /// Creates a fully configured settings dependency bundle.
    init(
        settings: AppPreferencesStore,
        runnerState: RunnerState,
        autoUpdater: AppUpdater,
        onSignIn: @escaping @MainActor () -> Void,
        onSignOut: @escaping @MainActor () async -> Void
    ) {
        self.settings = settings
        self.runnerState = runnerState
        self.autoUpdater = autoUpdater
        self.onSignIn = onSignIn
        self.onSignOut = onSignOut
    }
}
