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
///
/// Startup ordering:
///   LocalRunnerStore.configure    <- synchronous, in init()
///   oauthCredentials.reconcile    <- sync, in start() before first await
///   oauthCredentials.start        <- sync, in start() before first await
///   localRunnerStore.refreshAsync <- first suspension point
///   runnerStore.start             <- begins poll loop (owned by pollDriver Task)
@MainActor
@Observable
final class MigrationAppDependencies {
    /// Live runner state tree shared across all views in the windowed app.
    let runnerState: RunnerState
    /// Store that manages local (self-hosted) runner registration and refresh.
    let localRunnerStore: LocalRunnerStore
    /// Dependencies for the Settings scene (accounts, preferences, scopes).
    let settingsDependencies: MigrationSettingsDependencies
    /// Shared log fetcher — owns the ZIP cache for the windowed app lifetime.
    /// Exposed so views can thread it via `@Binding` into `StepLogContentView`.
    let logFetcher: LogFetcher

    /// GitHub authentication controller used for credential reconcile and OAuth flow.
    private let authentication: GitHubAuthentication
    /// Configured GitHub API client shared across all domain objects.
    private let github: GitHubClient
    /// Manages OAuth credential storage, refresh, and sign-out.
    private let oauthCredentials: OAuthCredentialController
    /// The live runner poller; `nil` until `start()` has been called once.
    private var runnerStore: (any RunnerPollerProtocol)?
    /// Unstructured task that owns the poll loop outside SwiftUI's `.task` lifecycle.
    /// `nil` until `start()` has been called once. `CancellationError` is the only
    /// reason to set this back to `nil` — the Task wrapper protects the loop from
    /// SwiftUI cancellation.
    private var pollDriver: Task<Void, Never>?

    /// Creates the dependency graph for the windowed migration app shell.
    /// - Parameters:
    ///   - authentication: GitHub authentication controller.
    ///   - onSignIn: Closure called on the main actor after a successful sign-in.
    ///   - onSignOut: Async closure called on the main actor after sign-out completes.
    init(
        authentication: GitHubAuthentication,
        onSignIn: @escaping @MainActor () -> Void,
        onSignOut: @escaping @MainActor () async -> Void
    ) {
        let state = RunnerState()
        self.runnerState = state
        self.authentication = authentication

        // MUST be synchronous and first (issue #1741).
        LocalRunnerStore.configure(viewModel: state)
        self.localRunnerStore = LocalRunnerStore.shared

        // GitHub client - same configuration as AppState.
        // WARNING: service/account match the pre-GitHubClient keychain entry name.
        // Do NOT change - doing so orphans stored tokens and forces re-authentication.
        let client = GitHubClient(
            clientID: OAuthSecrets.clientID,
            clientSecret: OAuthSecrets.clientSecret,
            service: "run-bot",
            account: "github-oauth-token",
            authSource: { authentication.selectedSource },
            logger: GitHubLoggerAdapter()
        )
        self.github = client

        // Poll-loop actor - mirrors AppState.seedStoreAndPoller().
        let poller = RunnerPoller(
            state: state,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            localRunners: { state.localRunners },
            applyMetrics: { metrics, id, name in
                await LocalRunnerStore.shared.applyMetrics(
                    metrics,
                    forRunnerId: id,
                    name: name
                )
            },
            notificationPreferences: NotificationPreferences.shared
        )
        self.runnerStore = poller

        // Credential controller - same init as AppState.
        // didSignOut restarts the poll loop after sign-out.
        let credentials = OAuthCredentialController(
            service: client.oauthService,
            authentication: authentication
        )
        credentials.didSignOut = { [weak poller] in
            await poller?.start()
        }
        self.oauthCredentials = credentials

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
        self.logFetcher = LogFetcher()
    }
}

// MARK: - Startup

/// Startup lifecycle for `MigrationAppDependencies`.
extension MigrationAppDependencies {
    /// Starts the domain pipeline: credential reconcile -> local refresh -> poll loop.
    ///
    /// Idempotent — the `pollDriver` guard prevents duplicate runs.
    ///
    /// Ordering mirrors the domain subset of AppState.start():
    ///   1. reconcile + start observations - sync, before first await
    ///   2. localRunnerStore.refreshAsync  - hydrates local runners
    ///   3. pollDriver Task                - begins GitHub poll loop (unstructured,
    ///      outside SwiftUI lifecycle)
    func start() async {
        guard pollDriver == nil else { return }

        // Step 1 - sync, before first suspension point.
        oauthCredentials.reconcile()
        oauthCredentials.start()

        // Step 2 - hydrate local runners before the poll loop fires.
        await localRunnerStore.refreshAsync()

        // Step 3 - begin GitHub Actions poll loop in an unstructured Task
        // so it survives SwiftUI `.task` cancellation.
        guard let store = runnerStore else { return }
        pollDriver = Task { [store] in
            while !Task.isCancelled {
                await store.start()
                log("poll cycle returned, dimmed groups=\(runnerState.actions.filter(\.isDimmed).count)")
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch is CancellationError {
                    break
                } catch {
                    break
                }
            }
        }
    }

    /// Triggers a poll-loop restart without the full startup sequence.
    ///
    /// Unlike `start()`, this method is **not** idempotent — it cancels the
    /// current poll driver and begins a fresh fetch cycle immediately. Designed
    /// to be called from scene-phase transitions (e.g. returning from sleep,
    /// reactivating the window) so the UI reflects the latest GitHub state
    /// without waiting for the next scheduled tick.
    ///
    /// If the poll driver is not yet running, this method kicks off the full
    /// startup sequence (same as `start()`).
    func refresh() async {
        await localRunnerStore.refreshAsync()
        if pollDriver == nil || pollDriver?.isCancelled == true {
            pollDriver = nil
            await start()
            return
        }
        guard let store = runnerStore else { return }
        await store.start()
    }
}
