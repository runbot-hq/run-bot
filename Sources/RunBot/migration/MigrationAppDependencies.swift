// MigrationAppDependencies.swift
// RunBot
import AppUpdater
import Foundation
import GitHubClient
import Observation
import RunBotCore

// MARK: - MigrationAppDependencies

/// Owns and configures the minimum domain dependencies required by the windowed app.
///
/// `LocalRunnerStore.configure(viewModel:)` must be the very first call,
/// synchronously, before any view is mounted. This mirrors the ordering rule
/// documented in `AppDelegate+StoreSetup.swift` (fix for issue #1741).
@MainActor
@Observable
final class MigrationAppDependencies {
    /// Observable runner state that `LocalRunnerStore` pushes snapshots into.
    let runnerState: RunnerState
    /// The configured local-runner store, ready for injection into views.
    let localRunnerStore: LocalRunnerStore

    /// Settings services.
    /// Owns the auth callbacks and updater needed by `MigrationSettingsView`.
    let settingsDependencies: MigrationSettingsDependencies

    /// Configures `LocalRunnerStore` synchronously then captures the shared instance.
    /// `settingsDependencies` is constructed after the runner store so it can
    /// share the already-created `RunnerState`.
    init(
        authentication: GitHubAuthentication,
        onSignIn: @escaping @MainActor () -> Void,
        onSignOut: @escaping @MainActor () async -> Void
    ) {
        let state = RunnerState()
        self.runnerState = state
        LocalRunnerStore.configure(viewModel: state)
        self.localRunnerStore = LocalRunnerStore.shared
        self.settingsDependencies = MigrationSettingsDependencies(
            settings: .shared,
            runnerState: state,
            autoUpdater: AppUpdater(
                repo: "runbot-hq/run-bot",
                currentVersion: Bundle.main.rbVersionString,
                assetName: { _ in "RunBot.zip" },
                publicKey: Data(base64Encoded: "lECb0Xv0zTET/Biw00rTtCl/sVdbzGG4WICYlG7g/oc=")
                    ?? { preconditionFailure("Ed25519 public key is not valid base64") }(),
                schedulerIdentifier: "io.github.runbot-hq.update-check",
                betaChannelProvider: { AppPreferencesStore.shared.betaChannel }
            ),
            onSignIn: onSignIn,
            onSignOut: onSignOut
        )
    }
}
