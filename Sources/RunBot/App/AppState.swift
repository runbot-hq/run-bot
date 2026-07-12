// AppState.swift
// RunBot

import Foundation   // ProcessInfo (UI_TESTING guard in start()). AppState intentionally
                    // does NOT use any AppKit UI types — NSPopover/NSStatusItem/etc stay
                    // on AppDelegate. ProcessInfo is Foundation, not AppKit.
import AppUpdater
import GitHubClient
import Observation
import RunBotCore

// MARK: - AppState
//
// Single coordinator for all domain-level state that was previously scattered
// across AppDelegate's property bag. AppDelegate is reduced to lifecycle
// wiring after this consolidation (issue #2040).
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
// construct a full AppState. This is an accepted trade-off: AppState's concrete
// types (GitHubClient, AppUpdater, RunnerLifecycleService) have no side effects
// at init time — side effects begin only when start() is called. Unit tests that
// don't call start() get a zero-cost AppState. A protocol extraction can be
// revisited if the test surface grows (tracked as migration debt in wrapEnv).
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
//   refreshAsync → store.start
//   → checkAndHandle → scheduleBackgroundCheck → startObservations()
// LocalRunnerStore.configure() is called by AppDelegate BEFORE the startup
// Task, not inside start() — see issue #1741 for why ordering matters.
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
    ///
    /// Testability note: constructing `AppState` is zero-cost (no side effects
    /// until `start()` is called), so a test can create `AppState()`, assign
    /// a stub to `lifecycleService` via a test-only `init`, and never call
    /// `start()`. The protocol typing here enables that pattern. A full
    /// `AppStateProtocol` extraction is deferred — see WHY NOT AppStateProtocol
    /// in the file-level comment.
    let lifecycleService: any RunnerLifecycleServiceProtocol = RunnerLifecycleService()

    /// Owned `LocalRunnerStore` actor.
    ///
    /// Backed by a private optional (`_localRunnerStore`) because `@Observable`
    /// does not support `lazy var` — the macro generates conflicting accessors.
    /// The manual backing pattern replicates lazy semantics without the conflict.
    ///
    /// ❌ NEVER read `localRunnerStore` before `start()` runs. `start()` seeds
    /// `_localRunnerStore` immediately after `configure()` is called (by AppDelegate
    /// before the startup Task), so all accesses inside `start()` take the fast
    /// path. The `assertionFailure` below is a guard against other early-read
    /// paths (e.g. previews) — it is NOT expected to fire during normal startup.
    ///
    /// WHY THE FALLBACK PATH EXISTS (it is NOT a safe-recovery path):
    /// Both the DEBUG and Release branches terminate the process — the only
    /// difference is crash-report attribution. DEBUG fires `assertionFailure`
    /// here so the crash site is `AppState.localRunnerStore` with a readable
    /// message. Release falls through to `LocalRunnerStore.shared`, which calls
    /// `fatalError` internally if `configure()` has not run. There is no silent
    /// recovery, no default value, and no retry. If you are reading this because
    /// the assertionFailure fired, fix the early-read path — do not remove the
    /// fallback or replace it with a nil-coalescing default.
    var localRunnerStore: LocalRunnerStore {
        if let store = _localRunnerStore { return store }
        // ──────────────────────────────────────────────────────────────────
        // UNREACHABLE during normal startup.
        // start() seeds _localRunnerStore (Step 1) before any access here.
        // If you are reading this because the assertionFailure fired, an
        // early-read path exists that bypasses start() — fix that, not this.
        // ──────────────────────────────────────────────────────────────────
        #if DEBUG
        // Fires in DEBUG only so the crash site is AppState.localRunnerStore
        // with a readable message, not a silent fatalError inside .shared.
        assertionFailure("AppState.localRunnerStore read before start() — _localRunnerStore not seeded yet")
        #endif
        // In Release the assertionFailure above is compiled out.
        // .shared will fatalError internally if configure() hasn't run,
        // which is the correct process-terminating outcome — just from a
        // different call site. This is NOT a safe-recovery path.
        let store = LocalRunnerStore.shared
        _localRunnerStore = store
        return store
    }
    /// Backing store for the `localRunnerStore` computed property.
    /// Seeded by `start()` immediately after `LocalRunnerStore.configure()` runs.
    private var _localRunnerStore: LocalRunnerStore?

    /// Idempotency sentinel for `start()`. Set to `true` unconditionally on the
    /// first call entry, before any early-return branches, so that a second call
    /// is always a no-op regardless of which branch the first call took
    /// (e.g. `UI_TESTING` return, future test stubs, etc.).
    private var _didStart = false

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
    ///
    /// Write-only by design: the value is never read after assignment. The
    /// assignment itself is what keeps the `Task` alive — without a strong
    /// reference the task is immediately cancelled by ARC. `periphery:ignore`
    /// suppresses the "assigned but never read" dead-code warning.
    ///
    /// `@Observable` tracking: these are `private var` on an `@Observable` class,
    /// so the macro synthesises observation registrar calls on both properties.
    /// Because nothing outside `AppState` reads them, those registrar calls are
    /// always no-ops at runtime — there is no observable overhead. Marking them
    /// `@ObservationIgnored` would be cleaner but is deliberately omitted to
    /// keep the declaration surface minimal; add it if profiling ever shows cost.
    private var statusIconTask: Task<Void, Never>?

    // periphery:ignore - write-only by design; assignment keeps the Task alive
    /// Retained handle for the sign-out observation task started in `start()`.
    ///
    /// Same write-only retention pattern as `statusIconTask` above.
    /// Both tasks use `Task { @MainActor [weak self] in }` — the explicit
    /// `@MainActor` annotation is intentional: both closures access
    /// `@MainActor`-isolated `AppState` properties (`oauthService`, `runnerStore`,
    /// `runnerState`). Without it, each property access would implicitly hop to
    /// the main actor inside the loop body, which (a) adds noise to the threading
    /// contract and (b) opens a TOCTOU window between `guard let store` and
    /// `await store.start()` across actor hops.
    private var signOutTask: Task<Void, Never>?

    // MARK: - Init

    /// Creates a new `AppState`. Call `start(onUpdateStatusIcon:)` after init to begin the startup sequence.
    init() {}

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
    /// 1. Seed `_localRunnerStore` from `LocalRunnerStore.shared` (already configured).
    /// 2. Create `RunnerPoller`.
    /// 3. `refreshAsync()` — hydrates local runners before poll loop fires.
    /// 4. `runnerStore.start()` — begins the poll loop.
    /// 5. `autoUpdater.checkAndHandle` — launch-time update check.
    /// 6. `autoUpdater.scheduleBackgroundCheck` — periodic update scheduler.
    /// 7. `startObservations()` — wires status-icon and sign-out tasks.
    ///
    /// Idempotency: guarded by `_didStart`, set unconditionally on first entry
    /// before any branch. A second call is always a no-op regardless of which
    /// early-return branch fired on the first call (e.g. `UI_TESTING`).
    ///
    /// - Parameter onUpdateStatusIcon: Called on `@MainActor` whenever
    ///   `runnerState.aggregateStatus` changes. ⚠️ Capture `AppDelegate` weakly
    ///   at the call site — this closure is stored inside a long-lived `Task`
    ///   for the process lifetime. A strong capture would retain `AppDelegate`
    ///   indefinitely. The call site in `AppDelegate+StoreSetup.swift` does
    ///   this correctly via `{ [weak self] in self?.updateStatusIcon() }`.
    func start(onUpdateStatusIcon: @escaping @MainActor () -> Void) async {
        guard !_didStart else {
            log("AppState › start — already called, skipping (idempotency guard)")
            return
        }
        _didStart = true
        // UI test isolation: skip all network/polling setup when running under XCTest.
        // The old setupSubscriptions() had the same guard — preserved here so UI tests
        // remain fast and network-free. AppDelegate still calls configure() before this
        // (needed for the SwiftUI env even in test runs), but the poll loop must not start.
        //
        // Skipping startObservations() here is intentional: the sign-out observation
        // loop and status-icon task are not started either. There is no poll loop
        // running in UI tests, so there is nothing to restart on sign-out. UI tests
        // test the UI — they do not simulate OAuth sign-out stream events.
        guard ProcessInfo.processInfo.environment["UI_TESTING"] == nil else {
            log("AppState › start — UI_TESTING detected, skipping network setup")
            return
        }
        log("AppState › start — begin (LocalRunnerStore.configure already called by AppDelegate)")

        // Step 1: seed the backing store so all accesses inside start() take the fast
        // path in the localRunnerStore getter and never trigger the assertionFailure.
        // configure() was called by AppDelegate synchronously before its first await
        // (issue #1741), so .shared is already fully initialised at this point.
        //
        // Historical note — why configure() must precede this line:
        // Before issue #1741, LocalRunnerStore self-initialised using RunnerViewModel.shared
        // as its view model. That singleton was a DIFFERENT object from AppState.runnerState,
        // so all local-runner pushes (localRunners, isLocalScanning) landed in a view model
        // that no SwiftUI view ever observed — producing a permanent empty local-runner list.
        // configure(viewModel: runnerState) wires the correct instance. ❌ NEVER remove it.
        _localRunnerStore = LocalRunnerStore.shared
        log("AppState › start — _localRunnerStore seeded")

        // Step 2: create RunnerPoller.
        // AppPreferencesStore.shared and ScopeStore.shared are passed explicitly
        // because default-value expressions cannot be @MainActor-isolated in
        // a nonisolated context (Swift 6).
        //
        // Note: there is no Combine sink here. The old RunnerStore.didUpdate sink
        // was removed when RunnerPoller replaced the timer-based poll loop.
        // RunnerPoller (a Swift actor in RunBotCore) pushes state directly into
        // runnerState via applyFetchResult on the @MainActor after every fetch cycle.
        // LocalRunnerStore pushes localRunners and isLocalScanning via configure().
        // All views read exclusively from runnerState — the migration from
        // RunnerViewModel/observable is complete. If you are wondering where the
        // Combine sink went: it no longer exists by design.
        //
        // Scope-change restarts: no explicit handling is needed here. RunnerPoller
        // internally observes ScopeStore.activeScopes via withObservationTracking /
        // AsyncStream and restarts its own poll loop when scopes change (add, remove,
        // enable toggle). AppState does not need to call start() on scope changes.
        //
        // The [localRunnerStore] capture list evaluates the computed property
        // here at construction time. Because _localRunnerStore was seeded above,
        // the fast path fires and the assertionFailure is NOT triggered.
        // If you move RunnerPoller construction before the seed line, DEBUG builds
        // will assertionFailure on every startup — don't reorder these.
        runnerStore = RunnerPoller(
            state: runnerState,
            preferencesStore: AppPreferencesStore.shared,
            scopeStore: ScopeStore.shared,
            // Capture runnerState directly — not via [weak self] — so a nil
            // AppState can never silently return [] and drop all local runners
            // from the poll cycle. runnerState is a @MainActor-isolated class
            // reference; capturing it directly is safe.
            localRunners: { [runnerState] in runnerState.localRunners },
            // Capture the stored property rather than LocalRunnerStore.shared
            // so a test double wired via _localRunnerStore is honoured here too.
            applyMetrics: { [localRunnerStore] metrics, id, name in
                await localRunnerStore.applyMetrics(metrics, forRunnerId: id, name: name)
            }
        )
        log("AppState › start — RunnerPoller created")

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
        // Called after `await store.start()` — safe because `Observations` has
        // did-set semantics: it emits once immediately with the current value on
        // first subscription, so any aggregateStatus writes that raced between
        // store.start() and this point are covered by the initial emission.
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
        //
        // Why store.start() is called after sign-out (PR #1138 regression history):
        // Before #1138, polling was driven by a Timer. After sign-out the timer fired,
        // fetch() ran, githubToken() found the keychain cleared, and naturally fell
        // through to env-var tokens (GH_TOKEN / GITHUB_TOKEN).
        // #1138 replaced the timer with a Task that loops on Task.sleep — it never
        // calls start() again on its own, so the env-token fallback only works if
        // start() is explicitly invoked after sign-out. That is what this loop does.
        // ❌ Do NOT remove the store.start() call — without it, signed-out users with
        //    a GH_TOKEN env var get a permanently stalled poll loop.
        //
        // Why this lives in AppState and not SettingsView:
        // SettingsView.signOutTask is stored in @State and is only alive while
        // Settings is visible. A user who signs out with Settings closed would
        // never trigger the restart. AppState is app-lifetime, so the listener
        // is always active regardless of which view is on screen.
        signOutTask = Task { @MainActor [weak self] in
            // `return` (not `continue`) for nil-self: the Task's outer loop has no
            // meaning if AppState is gone — exit the Task entirely rather than
            // spinning on a stream that can never do useful work.
            guard let self else { return }
            for await _ in self.oauthService.makeSignOutStream() {
                log("AppState › didSignOut — restarting poll loop for env-token fallback")
                // `continue` (not `return`) for nil-store: a missing runnerStore is a
                // transient / unexpected state, but AppState itself is still alive.
                // Continuing lets the loop handle future sign-out events rather than
                // killing the listener permanently.
                guard let store = self.runnerStore else {
                    log("AppState › didSignOut — ⚠️ runnerStore nil at sign-out time; skipping start()")
                    continue
                }
                await store.start()
            }
        }
    }
}
