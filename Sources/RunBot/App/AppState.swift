// AppState.swift
// RunBot

import AppKit
import AppUpdater
import GitHubClient
import Observation
import RunBotCore
import SwiftUI

// MARK: - AppState
//
// Single coordinator for all domain-level state that was previously scattered
// across AppDelegate's property bag. AppDelegate is reduced to lifecycle
// wiring (~50 lines) after this consolidation.
//
// OWNERSHIP RULES:
// ✅ AppState owns: domain services, poll actors, observable read models,
//    retained Task handles that observe domain state, and nav state.
// ❌ AppState does NOT own: NSPopover, NSStatusItem, NSHostingController,
//    MBKOverlayGate, PanelVisibilityState, PopoverLifecycleCoordinator,
//    PanelSheetState, or any AppKit wiring. Those stay on AppDelegate.
//
// LAYERING:
// AppState lives in the RunBot app target. It may import RunBotCore,
// GitHubClient, and AppUpdater. It must NOT import MenuBarKit — that
// would create a circular dependency (MBKOverlayGate is AppDelegate-owned
// specifically to honour this constraint).
//
// THREADING:
// @MainActor-isolated. All domain sub-objects that write observable state
// must hop to MainActor before writing (RunnerPoller does this via
// `await MainActor.run { }` at the end of every fetch cycle).
//
// STARTUP:
// AppDelegate.applicationDidFinishLaunching calls
// `await appState.start(onUpdateStatusIcon:)` after hydrating display names.
// AppState.start() runs the ordered async startup sequence:
//   LocalRunnerStore.configure → refreshAsync → store.start
//   → checkAndHandle → scheduleBackgroundCheck → startObservations()
//
// Ref: issue #2040, branch feat/app-state-consolidation

/// Coordinator for all domain-level state owned by the RunBot app process.
///
/// Injected into the SwiftUI environment as a single `.environment(appState)`
/// call inside `AppDelegate.wrapEnv(_:)`. Views access sub-objects via
/// `@Environment(AppState.self)`.
@Observable
@MainActor
final class AppState {

    // MARK: - Domain services

    /// The `GitHubClient` facade — owns and wires `KeychainTokenStore`,
    /// `TokenCache`, `OAuthService`, and `GitHubTransport`.
    ///
    /// ⚠️ Backward-compat: `service: "run-bot"` matches the keychain service
    /// name used by the pre-GitHubClient `Keychain` type. Do NOT change this
    /// value post-ship — doing so orphans any token already stored under the
    /// old coordinates and forces every signed-in user to re-authenticate.
    let github = GitHubClient(
        clientID: OAuthSecrets.clientID,
        clientSecret: OAuthSecrets.clientSecret,
        service: "run-bot",
        account: "github-oauth-token",
        logger: GitHubLoggerAdapter()
    )

    /// Forwarded from `github.oauthService` for backward-compatible access
    /// across extensions and injected views.
    var oauthService: any OAuthServiceProtocol { github.oauthService }

    /// Owned lifecycle service. Typed to protocol so tests can supply a stub
    /// without spawning real `svc.sh` processes (principle P7).
    let lifecycleService: any RunnerLifecycleServiceProtocol = RunnerLifecycleService()

    /// Owned `LocalRunnerStore` actor.
    ///
    /// Backed by a private optional so `LocalRunnerStore.shared` is never
    /// accessed before `LocalRunnerStore.configure(viewModel:)` is called in
    /// `start()`. `@Observable` does not support `lazy var`, so we use a
    /// manual backing pattern instead.
    ///
    /// ❌ NEVER read `localRunnerStore` before `start()` runs — it will
    /// trigger the `fatalError` guard inside `LocalRunnerStore.shared`.
    var localRunnerStore: LocalRunnerStore {
        if let store = _localRunnerStore { return store }
        #if DEBUG
        assertionFailure("AppState.localRunnerStore read before start() — LocalRunnerStore.shared has not been configured yet")
        #endif
        let store = LocalRunnerStore.shared
        _localRunnerStore = store
        return store
    }
    /// Backing store for the `localRunnerStore` computed property.
    private var _localRunnerStore: LocalRunnerStore?

    /// Owned `RunnerPoller` actor. `nil` until `start()` runs.
    ///
    /// Optional (not `!`) so the uninitialised state is representable at the
    /// type level and the compiler flags any force-unwrap at call sites (P4).
    ///
    /// ❌ NEVER add a `lazy var` default body here — doing so creates a
    /// dual-init path that produces competing poll loops.
    var runnerStore: (any RunnerPollerProtocol)?

    /// Observable read model for all Core-side runner/job/action/rate-limit state.
    ///
    /// Created here (not inside `start()`) so it survives for the full app
    /// lifetime. `RunnerPoller.applyFetchResult` writes into this instance on
    /// the `@MainActor` after every poll cycle. Views read from it via
    /// `@Environment(RunnerState.self)` or via `appState.runnerState`.
    let runnerState = RunnerState()

    /// Auto-update driver. Injected into `SettingsView` for the
    /// Install & Relaunch action and driven from `start()` on startup.
    let autoUpdater = AppUpdater(
        repo: "runbot-hq/run-bot",
        currentVersion: Bundle.main.rbVersionString,
        assetName: { _ in "RunBot.zip" },
        // 32-byte Ed25519 public key — safe to commit (public key, not secret).
        // Private key lives in Actions secret ED25519_PRIVATE_KEY — never commit it.
        publicKey: Data(base64Encoded: "lECb0Xv0zTET/Biw00rTtCl/sVdbzGG4WICYlG7g/oc=")
            ?? { preconditionFailure("Ed25519 public key is not valid base64 — check key after rotation") }(),
        schedulerIdentifier: "io.github.runbot-hq.update-check",
        betaChannelProvider: { AppPreferencesStore.shared.betaChannel }
    )

    // MARK: - Navigation state

    /// The last nav destination the user was on before the popover was closed
    /// or hidden. Restored by `AppDelegate.openPanel()` on re-open.
    var savedNavState: NavState?

    // MARK: - Retained task handles
    //
    // statusIconTask and signOutTask are co-located with AppState because they
    // observe/drive domain state (runnerState.aggregateStatus, oauthService
    // sign-out stream, runnerStore). Keeping them here means AppState owns
    // the full lifecycle of the domain observation loops.
    //
    // PanelSheetState stays on AppDelegate: clearRunnerSheet() is called from
    // closePanel() and the settings-back callback — both AppKit-level wiring
    // events, not domain events. Co-locating it with popover lifecycle is cleaner.

    // periphery:ignore - write-only by design; assignment keeps the Task alive
    /// Retained handle for the status-icon observation task started in `start()`.
    var statusIconTask: Task<Void, Never>?

    // periphery:ignore - write-only by design; assignment keeps the Task alive
    /// Retained handle for the sign-out observation task started in `start()`.
    var signOutTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new `AppState`. Call `start(onUpdateStatusIcon:)` after init to begin the startup sequence.
    init() {}

    // MARK: - Startup

    /// Ordered async startup sequence. Called once from
    /// `AppDelegate.applicationDidFinishLaunching` after display names are hydrated.
    ///
    /// Sequence:
    /// 1. `LocalRunnerStore.configure` — must precede the first await.
    /// 2. `refreshAsync()` — hydrates local runners before poll loop fires.
    /// 3. `runnerStore.start()` — begins the poll loop.
    /// 4. `autoUpdater.checkAndHandle` — launch-time update check.
    /// 5. `autoUpdater.scheduleBackgroundCheck` — periodic update scheduler.
    /// 6. `startObservations()` — wires status-icon and sign-out tasks.
    ///
    /// Idempotency: guarded by `runnerStore == nil` — a second call is a no-op.
    func start(onUpdateStatusIcon: @escaping @MainActor () -> Void) async {
        guard runnerStore == nil else {
            log("AppState › start — already configured, skipping (idempotency guard)")
            return
        }
        log("AppState › start — begin")

        // Step 1: configure LocalRunnerStore BEFORE the first await.
        // ⚠️ Must precede refreshDisplayNames and any indirect .shared access.
        LocalRunnerStore.configure(viewModel: runnerState)
        log("AppState › start — LocalRunnerStore configured")

        // Step 2: create RunnerPoller.
        // AppPreferencesStore.shared and ScopeStore.shared are passed explicitly
        // because default-value expressions cannot be @MainActor-isolated in
        // a nonisolated context (Swift 6).
        runnerStore = RunnerPoller(
            state: runnerState,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            localRunners: { [runnerState] in runnerState.localRunners },
            applyMetrics: { [localRunnerStore] metrics, id, name in
                await localRunnerStore.applyMetrics(metrics, forRunnerId: id, name: name)
            }
        )
        log("AppState › start — RunnerPoller created")

        // Step 3: await local runner hydration before starting the poll loop.
        log("AppState › start — awaiting localRunnerStore.refreshAsync()")
        await localRunnerStore.refreshAsync()
        log("AppState › start — refreshAsync complete")

        guard let store = runnerStore else {
            log("AppState › start — ⚠️ runnerStore nil after refreshAsync; poll loop NOT started")
            #if DEBUG
            assertionFailure("AppState.start: runnerStore is nil — structurally unreachable")
            #endif
            return
        }

        // Step 4: start the poll loop.
        await store.start()
        log("AppState › start — poll loop started")

        // Step 5: update check.
        await autoUpdater.checkAndHandle(state: runnerState)

        // Step 6: background update scheduler.
        autoUpdater.scheduleBackgroundCheck(state: runnerState)
        log("AppState › start — update background scheduler registered")

        // Step 7: wire domain observation tasks.
        startObservations(onUpdateStatusIcon: onUpdateStatusIcon)
        log("AppState › start — observations started")
    }

    // MARK: - Domain observation tasks

    /// Starts the two long-lived observation tasks:
    /// - `statusIconTask`: observes `runnerState.aggregateStatus` and calls back
    ///   to `AppDelegate` to update the menu-bar icon (AppKit concern stays in AppDelegate).
    /// - `signOutTask`: listens for OAuth sign-out events and restarts the poll loop.
    ///
    /// `onUpdateStatusIcon` is a callback rather than a direct AppDelegate reference
    /// to avoid AppState holding a strong reference to AppDelegate.
    private func startObservations(onUpdateStatusIcon: @escaping @MainActor () -> Void) {
        // Status icon observation.
        // Observations has did-set semantics: emits once immediately with the
        // current value, then on each subsequent change. The initial emission
        // seeds the menu-bar icon to the correct state at startup.
        statusIconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in Observations({ self.runnerState.aggregateStatus }) {
                onUpdateStatusIcon()
            }
        }

        // Sign-out observation.
        // @MainActor matches statusIconTask above — both tasks access @MainActor-isolated
        // AppState properties (oauthService, runnerStore). Explicit annotation avoids
        // implicit actor hops on each property access inside the loop and eliminates
        // any TOCTOU window between `guard let store` and `await store.start()`.
        signOutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in self.oauthService.makeSignOutStream() {
                log("AppState › didSignOut — restarting poll loop for env-token fallback")
                guard let store = self.runnerStore else {
                    log("AppState › didSignOut — ⚠️ runnerStore nil at sign-out time; skipping start()")
                    continue
                }
                await store.start()
            }
        }
    }
}
