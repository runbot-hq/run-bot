// RunBotRuntime.swift
// RunBot
import AppKit
import AppUpdater
import Foundation
import GitHubClient
import Observation
import RunBotCore

// MARK: - RunBotRuntime

/// Owns and configures the long-lived domain services required by the windowed app.
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
///   runnerStore.start             <- begins poll loop
@MainActor
@Observable
final class RunBotRuntime {
    /// Live runner state tree shared across all views in the windowed app.
    let runnerState: RunnerState
    /// Store that manages local (self-hosted) runner registration and refresh.
    let localRunnerStore: LocalRunnerStore
    /// Dependencies for the Settings scene (accounts, preferences, scopes).
    let settingsDependencies: SettingsDependencies

    /// GitHub authentication controller used for credential reconcile and OAuth flow.
    private let authentication: GitHubAuthentication
    /// Configured GitHub API client shared across all domain objects.
    private let github: GitHubClient
    /// Manages OAuth credential storage, refresh, and sign-out.
    private let oauthCredentials: OAuthCredentialController
    /// The live runner poller; `nil` until `start()` has been called once.
    private var runnerStore: (any RunnerPollerProtocol)?
    /// Guards against duplicate `start()` calls (SwiftUI `.task` can fire more than once).
    private var didStart = false

    /// Creates the domain runtime for the windowed app shell.
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

        self.settingsDependencies = SettingsDependencies(
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
            notifications: NotificationPreferences.shared,
            onSignIn: { [weak credentials] in
                guard let url = credentials?.makeSignInURL() else { return }
                NSWorkspace.shared.open(url)
            },
            onSignOut: { [weak credentials] in
                await credentials?.signOut()
            },
            refreshAuthentication: { [weak authentication, weak client] in
                guard let authentication, let client else { return }
                authentication.syncOAuthState(
                    isAuthenticated: client.oauthService.isAuthenticated
                )
                authentication.setEnvironmentState(.checking)
                let environmentState = await client.discoverEnvironmentState()
                authentication.setEnvironmentState(environmentState)
            }
        )
    }
}

// MARK: - OAuth callback

/// OAuth callback handling for the windowed SwiftUI lifecycle.
extension RunBotRuntime {
    /// Forwards a macOS open-URL event to the OAuth service so the
    /// authorization code can be exchanged for a token.
    ///
    /// Call this from `.onOpenURL` in the SwiftUI `Window` scene.
    /// Uses the exact `github.oauthService` instance that created the
    /// sign-in URL — no second OAuth service is constructed.
    @MainActor
    func handleOAuthCallback(_ url: URL) {
        github.oauthService.handleCallback(url)
    }
}

// MARK: - Startup

/// Startup lifecycle for `RunBotRuntime`.
extension RunBotRuntime {
    /// Starts the domain pipeline: credential reconcile -> local refresh -> poll loop.
    ///
    /// Idempotent - SwiftUI may recreate the root .task; subsequent calls are no-ops.
    ///
    /// Ordering mirrors the domain subset of AppState.start():
    ///   1. reconcile + start observations - sync, before first await
    ///   2. localRunnerStore.refreshAsync  - hydrates local runners
    ///   3. runnerStore.start              - begins GitHub poll loop
    func start() async {
        guard !didStart else { return }
        didStart = true

        // Step 1 - sync, before first suspension point.
        oauthCredentials.reconcile()
        oauthCredentials.start()

        // Step 2 - hydrate local runners before the poll loop fires.
        await localRunnerStore.refreshAsync()

        // Step 3 - begin GitHub Actions poll loop.
        guard let store = runnerStore else { return }
        await store.start()
    }
}
