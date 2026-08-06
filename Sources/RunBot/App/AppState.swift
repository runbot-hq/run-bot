// AppState.swift
// RunBot

import AppUpdater
import Foundation   // ProcessInfo (UI_TESTING guard in start()). AppState intentionally
                    // does NOT use any AppKit UI types — NSPopover/NSStatusItem/etc stay
                    // on AppDelegate. ProcessInfo is Foundation, not AppKit.
import GitHubClient
import Observation
import RunBotCore

// MARK: - AppState
//
// Single coordinator for all domain-level state that was previously scattered
// across AppDelegate's property bag (issue #2040).
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
// WHY NOT AppStateProtocol?
// SettingsView previously accepted protocol-typed service parameters so tests
// could inject stubs. With AppState as the single injection point, tests must
// construct a full AppState — an accepted trade-off since AppState's concrete
// types have no side effects at init time (tracked as migration debt in wrapEnv).
//
// THREADING:
// @MainActor-isolated. Domain sub-objects that write observable state hop
// to MainActor via `await MainActor.run { }` at the end of every fetch cycle.
//
// STARTUP:
// AppDelegate calls `await appState.start(onUpdateStatusIcon:)` after
// hydrating display names. AppState.start() runs the ordered async startup:
//   seedStoreAndPoller → startObservations → refreshAsync → store.start
//   → checkAndHandle → scheduleBackgroundCheck
// LocalRunnerStore.configure() is called by AppDelegate BEFORE the startup
// Task, not inside start() (issue #1741).
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

    /// `GitHubClient` facade — owns `KeychainTokenStore`, `TokenCache`,
    /// `OAuthService`, and `GitHubTransport`.
    ///
    /// ⚠️ `service: "run-bot"` matches the pre-GitHubClient keychain service name.
    /// Do NOT change — doing so orphans stored tokens and forces re-authentication.
    let github: GitHubClient

    /// Read-only forwarding accessor to `github.oauthService`.
    var oauthService: any OAuthServiceProtocol { github.oauthService }

    /// Lifecycle service; protocol-typed so tests can inject a stub without
    /// spawning real `svc.sh` processes. Zero side-effects until `start()` is called.
    var lifecycleService: any RunnerLifecycleServiceProtocol = RunnerLifecycleService()

    /// Owned `LocalRunnerStore` actor. Backed by a private optional because
    /// `@Observable` does not support `lazy var`.
    ///
    /// ❌ NEVER read before `start()` runs — `start()` seeds `_localRunnerStore`
    /// before any access. The getter below terminates via `fatalError` if reached;
    /// both DEBUG and Release paths are fatal. If this fires, fix the early-read
    /// path — do not replace the fatalError with a nil-coalescing default.
    var localRunnerStore: LocalRunnerStore {
        if let store = _localRunnerStore { return store }
        // ──────────────────────────────────────────────────────────────────
        // UNREACHABLE during normal startup.
        // start() seeds _localRunnerStore (Step 1) before any access here.
        // If you are reading this because the assertionFailure fired, an
        // early-read path exists that bypasses start() — fix that, not this.
        // ──────────────────────────────────────────────────────────────────
        // Both DEBUG and Release terminate via fatalError below.
        // assertionFailure in DEBUG adds a debugger pause and readable message
        // at this call site, but does NOT prevent fatalError from firing —
        // execution continues past assertionFailure unconditionally.
        // ⚠️ Do NOT replace this with a nil-coalescing default or .shared fallback
        //    — doing so would mask the missed start() call in Release builds.
        #if DEBUG
        assertionFailure("AppState.localRunnerStore read before start() — fix the early-read path, not this getter")
        #endif
        fatalError("AppState.localRunnerStore accessed before start() — _localRunnerStore not seeded")
    }
    /// Backing store for the `localRunnerStore` computed property.
    /// Seeded by `start()` immediately after `LocalRunnerStore.configure()` runs.
    /// `@ObservationIgnored` because this is a write-only backing field — nothing
    /// outside `AppState` reads it, so the `@Observable` macro's synthesised
    /// registrar calls would be unconditional no-ops. Marking it ignored removes
    /// that dead overhead and makes the intent explicit.
    @ObservationIgnored private var _localRunnerStore: LocalRunnerStore?

    /// Idempotency sentinel for `start()`. Set to `true` unconditionally on the
    /// first call entry, before any early-return branches, so that a second call
    /// is always a no-op regardless of which branch the first call took
    /// (e.g. `UI_TESTING` return, future test stubs, etc.).
    /// `@ObservationIgnored` for the same reason as `_localRunnerStore` above —
    /// write-only sentinel, never observed externally, registrar calls are no-ops.
    /// ❌ NOT `nonisolated(unsafe)` (unlike `statusIconTask`):
    /// `_didStart` is only ever read/written inside `@MainActor`-isolated `start()`.
    /// `deinit` never touches it. The `nonisolated(unsafe)` annotation on the task
    /// vars exists solely because `deinit` calls `.cancel()` on them — that pattern
    /// does not apply here. Adding `nonisolated(unsafe)` would be misleading noise.
    @ObservationIgnored private var _didStart = false  // permanent per instance — do not reuse AppState across test setUp/tearDown

    /// Owned `RunnerPoller` actor. `nil` until `start()` runs.
    ///
    /// Optional (not `!`) so the uninitialised state is representable at the
    /// type level and the compiler flags any force-unwrap at call sites (P4).
    ///
    /// ❌ NEVER add a `lazy var` default body here — doing so creates a
    /// dual-init path that produces competing poll loops.
    ///
    /// `AppPreferencesStore.shared` and `ScopeStore.shared` are passed explicitly
    /// at the `RunnerPoller` init site in `start()` rather than used as parameter
    /// defaults because Swift 6 does not allow `@MainActor`-isolated expressions
    /// as default values in a nonisolated context.
    private var runnerStore: (any RunnerPollerProtocol)?

    /// Observable read model for all Core-side runner/job/action/rate-limit state.
    ///
    /// Created here (not inside `start()`) so it survives for the full app
    /// lifetime. `RunnerPoller.applyFetchResult` writes into this instance on
    /// the `@MainActor` after every poll cycle. Views read from it via
    /// Views read from it by declaring `@Environment(AppState.self) var appState`
    /// and accessing `appState.runnerState`.
    let runnerState = RunnerState()

    /// Auto-update driver. Injected into `SettingsView` for the
    /// Install & Relaunch action and driven from `start()` on startup.
    let autoUpdater = AppUpdater(
        repo: "runbot-hq/run-bot",
        currentVersion: Bundle.main.rbVersionString,
        assetName: { _ in "RunBot.zip" },
        // 32-byte Ed25519 public key — safe to commit (public key, not secret).
        // Private key lives in Actions secret ED25519_PRIVATE_KEY — never commit it.
        //
        // API shape note (AppUpdater#46): the parameter is `publicKey: Data` (raw bytes).
        // An earlier spec draft called it `ed25519PublicKey: String` — that API was
        // never shipped. If the call site looks wrong after an AppUpdater upgrade,
        // check the release notes for AppUpdater#46.
        //
        // preconditionFailure (rather than nil-coalescing to a default) is intentional:
        // a silent fallback would disable update-signature verification with no visible
        // error, which is strictly worse than a crash on a dev machine. AppUpdater.init
        // also has its own `precondition(publicKey.count == 32)` as a second guard.
        publicKey: Data(base64Encoded: "lECb0Xv0zTET/Biw00rTtCl/sVdbzGG4WICYlG7g/oc=")
            ?? { preconditionFailure("Ed25519 public key is not valid base64 — check key after rotation") }(),
        schedulerIdentifier: "io.github.runbot-hq.update-check",
        betaChannelProvider: { AppPreferencesStore.shared.betaChannel }
    )

    // MARK: - Authentication state

    /// Observable authentication state model (#2459).
    ///
    /// Single source of truth for:
    ///   • `selectedSource` — which credential the app uses for API requests.
    ///   • `environmentState` — env token availability (GH_TOKEN / GITHUB_TOKEN).
    ///   • `oauthState`  — mirrors OAuth Keychain credential presence: `.signedOut`
    ///     when no token exists and `.signedIn` when a token exists.
    ///
    /// `selectedSource` is persisted to `UserDefaults` and survives relaunches.
    /// Settings UI reads and mutates this model; `SettingsView.onAppearAction()`
    /// seeds `oauthState` from `oauthService` on every re-open, and Task 1 seeds
    /// `environmentState` via `github.token()` (login-shell fallback).
    ///
    /// `@ObservationIgnored` is NOT used here — SwiftUI views read from this
    /// instance and must receive change notifications when the model mutates.
    let authentication = GitHubAuthentication()

    // MARK: - Navigation state

    /// The last nav destination the user was on before the popover was closed
    /// or hidden. Restored by `AppDelegate.openPanel()` on re-open.
    var savedNavState: NavState?

    /// Shared `LogFetcher` instance owned above the `.id(navState)` boundary
    /// in `RootPanelView`. Owning it here means the ZIP cache (`zipCache`)
    /// survives across step-tap navigation: every step tap recreates
    /// `StepLogView`, but `AppState` is not remounted, so the cache persists
    /// for the lifetime of the panel session.
    ///
    /// ⚠️ Must be constructed after `github` so the transport is already wired.
    var logFetcher: LogFetcher

    // MARK: - Retained task handles
    //
    // statusIconTask is co-located with AppState because it observes domain state
    // (runnerState.aggregateStatus). Keeping it here means AppState owns the full
    // lifecycle of the status-icon observation loop.
    //
    // PanelSheetState stays on AppDelegate: clearRunnerSheet() is called from
    // closePanel() and the settings-back callback — both AppKit-level wiring
    // events, not domain events. Co-locating it with popover lifecycle is cleaner.

    /// Write-only task handle — the assignment keeps the Task alive (ARC).
    /// `@ObservationIgnored`: never read externally, no-op registrar calls.
    /// `nonisolated(unsafe)`: lets `deinit` call `.cancel()` safely; Task.cancel()
    /// is thread-safe and writes only happen on @MainActor in startObservations().
    @ObservationIgnored nonisolated(unsafe) private var statusIconTask: Task<Void, Never>?

    /// App-lifetime OAuth credential controller.
    /// Owns the sign-in observer and direct sign-out sequence. AppState only
    /// injects the runner-poll restart callback.
    let oauthCredentials: OAuthCredentialController

    // MARK: - Init

    /// Creates a new `AppState` with the default production `RunnerLifecycleService`.
    /// Call `start(onUpdateStatusIcon:)` after init to begin the startup sequence.
    init() {
        self.github = GitHubClient(
            clientID: OAuthSecrets.clientID,
            clientSecret: OAuthSecrets.clientSecret,
            service: "run-bot",
            account: "github-oauth-token",
            authSource: { [authentication] in authentication.selectedSource },
            logger: GitHubLoggerAdapter()
        )
        self.logFetcher = LogFetcher(transport: github.transport)

        self.oauthCredentials = OAuthCredentialController(
            service: github.oauthService,
            authentication: authentication
        )
        self.oauthCredentials.didSignOut = { [weak self] in
            guard let runnerStore = self?.runnerStore else {
                log(
                    "OAuthCredentialController › runnerStore unavailable; "
                        + "skipping poll restart"
                )
                return
            }
            await runnerStore.start()
        }
    }

    /// Test-only initialiser. Injects a stub `RunnerLifecycleServiceProtocol`
    /// so unit tests can exercise `AppState` without spawning real `svc.sh`
    /// processes (principle P7). Never call `start()` from test code unless
    /// the test explicitly needs the poll loop.
    ///
    /// - Parameter lifecycleService: A stub conforming to
    ///   `RunnerLifecycleServiceProtocol`. Pass a test double or a no-op mock.
    init(lifecycleService: any RunnerLifecycleServiceProtocol) {
        self.github = GitHubClient(
            clientID: OAuthSecrets.clientID,
            clientSecret: OAuthSecrets.clientSecret,
            service: "run-bot",
            account: "github-oauth-token",
            authSource: { [authentication] in authentication.selectedSource },
            logger: GitHubLoggerAdapter()
        )
        self.lifecycleService = lifecycleService
        self.logFetcher = LogFetcher(transport: github.transport)

        self.oauthCredentials = OAuthCredentialController(
            service: github.oauthService,
            authentication: authentication
        )
        self.oauthCredentials.didSignOut = { [weak self] in
            guard let runnerStore = self?.runnerStore else {
                log(
                    "OAuthCredentialController › runnerStore unavailable; "
                        + "skipping poll restart"
                )
                return
            }
            await runnerStore.start()
        }
    }

    deinit {
        // Cancel long-lived observation tasks so test processes that construct
        // AppState and call start() don't leak tasks beyond the test lifetime.
        // In production AppState lives for the process lifetime; deinit never fires.
        //
        // WHY nonisolated(unsafe) on the task vars (not @MainActor deinit):
        // Swift 6 deinit is nonisolated and cannot access @MainActor-isolated
        // properties. Task.cancel() is documented as thread-safe, and writes to
        // these vars only happen on @MainActor inside startObservations(). The
        // nonisolated(unsafe) annotation opts out of the actor-isolation check;
        // the data-race safety is upheld by the write-on-MainActor / cancel-in-
        // deinit ordering (deinit runs after the last strong reference drops,
        // so no concurrent write can occur at this point).
        statusIconTask?.cancel()
        // oauthCredentials cancels its own signInTask in its deinit.
    }

    // MARK: - Startup

    /// Ordered async startup sequence. Called once from
    /// `AppDelegate.applicationDidFinishLaunching` after `LocalRunnerStore.configure()`
    /// and display-name hydration have already completed.
    ///
    /// ⚠️ Precondition: `LocalRunnerStore.configure(viewModel:)` MUST have been called
    /// by the caller (AppDelegate) synchronously before its first `await`, per the
    /// fix for issue #1741. This method assumes configure has already run.
    ///
    /// ❌ NEVER move `LocalRunnerStore.configure()` inside this method or inside the
    /// startup `Task {}` in `applicationDidFinishLaunching`. configure() must be
    /// synchronous and before any await so that any @MainActor work enqueued during
    /// the first suspension point (refreshDisplayNames) cannot reach
    /// `LocalRunnerStore.shared` before configure has run.
    ///
    /// Sequence:
    /// 1. `seedStoreAndPoller()` — sync; seeds `_localRunnerStore` and creates `RunnerPoller`.
    /// 2. `startObservations()` — sync; reconciles OAuth credentials and installs
    ///    the status-icon and app-lifetime OAuth sign-in observations before any await.
    /// 3. `refreshAsync()` — first suspension point; hydrates local runners before poll loop fires.
    /// 4. `runnerStore.start()` — begins the poll loop. The first `token()` call suspends
    ///    here on a cold Finder/Dock/login-item launch (~50–200 ms login shell) then caches
    ///    the result. Terminal/CI/OAuth launches resolve from ProcessInfo or Keychain and
    ///    return immediately.
    /// 5. `autoUpdater.checkAndHandle` — launch-time update check.
    /// 6. `autoUpdater.scheduleBackgroundCheck` — periodic update scheduler.
    ///
    /// Idempotency: guarded by `_didStart`, set unconditionally on first entry
    /// before any branch. A second call is always a no-op regardless of which
    /// early-return branch fired on the first call (e.g. `UI_TESTING`).
    ///
    /// - Parameter onUpdateStatusIcon: Called on `@MainActor` whenever
    ///   `runnerState.aggregateStatus` changes.
    ///
    ///   ❌ No retain cycle today: the call site passes `{ [weak self] in self?.updateStatusIcon() }`,
    ///   so `AppState` does not retain `AppDelegate` through this closure.
    ///
    ///   ⚠️ Future call sites MUST also use a weakly-capturing closure. There is no
    ///   compiler-enforced guarantee. `AppState` cannot accept a weak `AppDelegate`
    ///   directly (that would require importing AppKit, violating the layering rule
    ///   that domain objects must not depend on AppKit). The callback pattern is the
    ///   correct trade-off; the weak-capture discipline must be enforced at every call site.
    func start(onUpdateStatusIcon: @escaping @MainActor () -> Void) async {
        guard !_didStart else {
            log("AppState › start — already called, no-op (idempotency guard; if this fires during UI_TESTING it means the first call already set _didStart and returned early)")
            return
        }
        _didStart = true
        // ⚠️ _didStart is set BEFORE the UI_TESTING early-return below. This is
        // intentional: a second call must be a no-op regardless of which branch
        // the first call took. Setting it after the guard would allow a second
        // call to slip through if the first returned via UI_TESTING. This does
        // mean a single AppState *instance* cannot be re-started after teardown —
        // _didStart is per-instance state, not process-global. Tests that construct
        // a fresh AppState() per test case are unaffected (each instance has its own
        // _didStart = false). The constraint only bites if the same instance is reused
        // across setUp/tearDown cycles, which is not a supported pattern.
        //
        // UI test isolation: skip all network/polling setup when running under XCTest.
        // The old setupSubscriptions() had the same guard — preserved here so UI tests
        // remain fast and network-free. AppDelegate still calls configure() before this
        // (needed for the SwiftUI env even in test runs), but the poll loop must not start.
        //
        // Skipping startObservations() here is intentional: the status-icon task
        // is not started. There is no poll loop running in UI tests, so there is
        // nothing to restart on sign-out.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppState › start — UI_TESTING detected, skipping network setup")
            return
        }
        log("AppState › start — begin (LocalRunnerStore.configure already called by AppDelegate)")

        // Step 0: seed GitHubAuthentication from live credential stores on cold launch.
        // OAuth sync is synchronous so there is no `.signedOut` flash before the poll
        // loop starts (Step 4). Env discovery runs in a detached Task (login-shell
        // probe can take ~50–200ms). syncOAuthState — NOT recordOAuthSignIn — so the
        // persisted `selectedSource` is never overwritten here (fix for #2464).
        authentication.syncOAuthState(isAuthenticated: oauthService.isAuthenticated)
        Task { @MainActor [authentication, github] in
            authentication.setEnvironmentState(await github.discoverEnvironmentState())
        }
        log("AppState › start — auth seeded (oauth=\(authentication.oauthState), source=\(authentication.selectedSource))")

        seedStoreAndPoller()  // Step 1: kept in a helper to stay within function_body_length.

        // Step 2: wire domain observation tasks BEFORE any await.
        // statusIconTask uses Observations{} which has did-set semantics (emits the
        // current aggregateStatus on first subscription), so wiring it here rather
        // than after store.start() is safe — any status writes that race are covered
        // by the initial emission when the loop first iterates.
        startObservations(onUpdateStatusIcon: onUpdateStatusIcon)
        log("AppState › start — observations wired")

        // Step 3: await local runner hydration before starting the poll loop.
        // refreshAsync() suspends until disk hydration completes; refresh() (the
        // fire-and-forget variant) would return immediately and let store.start()
        // fire fetch() on the very next runloop turn — before the refresh Task
        // has a chance to run. Result on cycle 1: localRunners=[], installPathMap
        // empty, metrics missing on first runner appearance. refreshAsync() closes
        // that race entirely.
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
        // On a cold Finder/Dock/login-item launch, the first poll cycle's token()
        // call suspends here for ~50–200 ms while the login shell sources
        // ~/.zprofile and ~/.zshrc to recover GH_TOKEN. The result is cached;
        // all subsequent poll cycles return immediately from the in-memory cache.
        // Terminal, CI, and Keychain OAuth launches resolve from ProcessInfo or
        // Keychain and do not spawn a shell.
        await store.start()
        log("AppState › start — poll loop started")

        // Step 5 & 6: update check + background scheduler.
        // Both are gated on the user’s `automaticUpdatesEnabled` preference (#2501).
        // When the user opts out, no check fires on launch and no scheduler is
        // registered for the session. If the user re-enables automatic updates at
        // runtime, `automaticUpdatesPreferenceDidChange(enabled: true)` (called from
        // SettingsView via an `.onChange` modifier) starts both paths.
        if AppPreferencesStore.shared.automaticUpdatesEnabled {
            await autoUpdater.checkAndHandle(state: runnerState)
            autoUpdater.scheduleBackgroundCheck(state: runnerState)
            log("AppState › start — update check + background scheduler registered")
        } else {
            log("AppState › start — automatic updates disabled; skipping check and scheduler (#2501)")
        }
    }

    // MARK: - Startup helpers

    /// Seeds `_localRunnerStore` and creates `RunnerPoller` (Step 1 of the
    /// startup sequence). Extracted from `start()` to keep that function within
    /// the SwiftLint `function_body_length` warning threshold (90 lines).
    ///
    /// Ordering constraints (do not reorder these two operations):
    /// 1. `_localRunnerStore` must be seeded first — the `[localRunnerStore]`
    ///    capture list in the `RunnerPoller` init evaluates the computed property
    ///    at construction time. Seeding first ensures the fast path fires and
    ///    the `assertionFailure` is never triggered on startup.
    /// 2. `LocalRunnerStore.configure()` must have been called by `AppDelegate`
    ///    synchronously before the startup `Task {}` (issue #1741), so `.shared`
    ///    is fully initialised when we read it here.
    ///
    /// Historical note — why configure() must precede this method:
    /// Before #1741, `LocalRunnerStore` self-initialised with `RunnerViewModel.shared`,
    /// a different object from `AppState.runnerState`. Local-runner pushes landed in
    /// a view model no view observed, producing a permanent empty local-runner list.
    /// `configure(viewModel: runnerState)` wires the correct instance. ❌ NEVER remove it.
    ///
    /// Note on the missing Combine sink: the old `RunnerStore.didUpdate` sink was
    /// removed when `RunnerPoller` replaced the timer-based poll loop. `RunnerPoller`
    /// pushes state directly into `runnerState` via `applyFetchResult` on `@MainActor`
    /// after every fetch cycle — no sink needed. Scope-change restarts are handled
    /// internally by `RunnerPoller` via `withObservationTracking` / `AsyncStream`.
    private func seedStoreAndPoller() {
        // Step 1a
        // Tripwire: if configure() was not called before start(), LocalRunnerStore.shared
        // will fatalError below. This assert fires in DEBUG/test runs first, giving a
        // readable message closer to the actual cause than the fatalError in .shared.
        assert(LocalRunnerStore.sharedInstance != nil, "AppState.seedStoreAndPoller: LocalRunnerStore.configure() must be called by AppDelegate before AppState.start()")
        _localRunnerStore = LocalRunnerStore.shared
        log("AppState › start — _localRunnerStore seeded")

        // Step 1b
        // `AppPreferencesStore.shared` and `ScopeStore.shared` are passed explicitly
        // because Swift 6 does not allow `@MainActor`-isolated expressions as
        // default-value arguments in a nonisolated context.
        runnerStore = RunnerPoller(
            state: runnerState,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            // Capture runnerState directly (not [weak self]) — a nil AppState
            // must never silently drop local runners from the poll cycle.
            localRunners: { [runnerState] in runnerState.localRunners },
            // Capture the computed property at RunnerPoller init time — the
            // value resolves to _localRunnerStore (seeded in Step 1a above) and
            // is frozen into the closure. A test double must be in place before
            // seedStoreAndPoller() runs; post-init replacement of _localRunnerStore
            // will NOT be reflected in this capture.
            applyMetrics: { [localRunnerStore] metrics, id, name in
                await localRunnerStore.applyMetrics(metrics, forRunnerId: id, name: name)
            },
            notificationPreferences: NotificationPreferences.shared
        )
        log("AppState › start — RunnerPoller created")
    }

    // MARK: - Domain observation tasks

    /// Starts the long-lived observation tasks:
    /// - `statusIconTask`: observes `runnerState.aggregateStatus` and calls back
    ///   to `AppDelegate` to update the menu-bar icon (AppKit concern stays in AppDelegate).
    /// - `oauthCredentials`: reconciles Keychain state, then begins the single
    ///   app-lifetime sign-in observation. Its injected `didSignOut` callback
    ///   restarts runner polling after direct sign-out.
    ///
    /// `onUpdateStatusIcon` is a callback rather than a direct AppDelegate reference
    /// to avoid AppState holding a strong reference to AppDelegate.
    private func startObservations(onUpdateStatusIcon: @escaping @MainActor () -> Void) {
        // Status icon observation.
        // Wired at Step 2 — BEFORE any suspension point. This is safe because
        // Observations{} has did-set semantics: it emits once immediately with the
        // current aggregateStatus on first subscription, so any status writes that
        // race between here and store.start() are covered by that initial emission.
        // Do NOT move this after any await — see the Step 2 comment
        // in start() for the sign-out window reasoning.
        //
        // CAPTURE NOTE: `onUpdateStatusIcon` is captured strongly inside this Task
        // and lives for the process lifetime. AppDelegate must pass a weakly
        // capturing closure — e.g. `{ [weak self] in self?.updateStatusIcon() }`
        // — so that AppState does NOT retain AppDelegate. Do NOT change the call
        // site in AppDelegate+StoreSetup.swift to a strong capture.
        statusIconTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await _ in Observations({ self.runnerState.aggregateStatus }) {
                onUpdateStatusIcon()
            }
        }

        // OAuth credential controller (issue #2481).
        // reconcile() syncs Keychain truth immediately so the button reflects the
        // correct state before the first render. start() registers the app-lifetime
        // sign-in observer. Both calls happen before any suspension point so no
        // browser callback can be missed between startup and the first await.
        // Runner-poll restart after sign-out is performed by the injected didSignOut callback.
        oauthCredentials.reconcile()
        oauthCredentials.start()
    }

    // MARK: - Automatic updates preference (#2501)

    /// Called by `SettingsView` when the user toggles the automatic-updates
    /// preference at runtime.
    ///
    /// **Disabling (`enabled == false`):**
    /// - Resets `runnerState` to `.idle` so no stale phase UI persists.
    /// - Does NOT stop an already-running `NSBackgroundActivityScheduler`;
    ///   `scheduleBackgroundCheck` intentionally has no public cancel API
    ///   (see `AppUpdater+BackgroundScheduler.swift` for rationale). In
    ///   practice this is harmless: the scheduler fires at most once per
    ///   24 h, and the gate in this method prevents a new scheduler from
    ///   being registered next launch.
    ///
    /// **Enabling (`enabled == true`):**
    /// - Fires an immediate check.
    /// - Registers a fresh periodic scheduler.
    ///   `scheduleBackgroundCheck` invalidates any existing scheduler before
    ///   registering the new one (see `activity?.invalidate()` in
    ///   `AppUpdater+BackgroundScheduler.swift`), so this is safe to call
    ///   more than once.
    func automaticUpdatesPreferenceDidChange(enabled: Bool) {
        log("AppState › automaticUpdatesPreferenceDidChange — enabled=\(enabled)")
        if enabled {
            Task { await autoUpdater.checkAndHandle(state: runnerState) }
            autoUpdater.scheduleBackgroundCheck(state: runnerState)
            log("AppState › automaticUpdatesPreferenceDidChange — check + scheduler started")
        } else {
            runnerState.apply(.idle)
            log("AppState › automaticUpdatesPreferenceDidChange — phase cleared to .idle")
        }
    }
}
