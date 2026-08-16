// RunBotDesktopApp.swift
// RunBot

import GitHubClient
import MenuBarKit
import RunBotCore
import SwiftUI

// @main removed: Sources/RunBot/main.swift is top-level code.
// RunBotDesktopApp.main() is called from main.swift instead.

/// The SwiftUI application entry point for RunBot.
/// `@main` is intentionally absent because `main.swift` invokes `main()`.
struct RunBotDesktopApp: App {
    /// Single domain-level state coordinator owned by this process.
    /// The windowed app uses the same `AppState` runtime implementation and
    /// event-publication chain that the menu-bar interface used — the same
    /// `RunnerState`, `RunnerPoller`, `GitHubClient`, and `OAuthCredentialController`.
    /// When the poller publishes a completed snapshot, all views invalidate reactively.
    @State private var appState: AppState

    /// Runner dependencies configured as a thin adapter around `AppState`.
    /// Constructed in `init()` so it shares the same `appState` instance.
    @State private var deps: MigrationAppDependencies
    /// Single overlay gate for the scene lifetime.
    ///
    /// Injected at the root of both the legacy panel hierarchy and the windowed
    /// app hierarchy. `MBKOverlayGate` is presentation infrastructure; it is not
    /// placed in `MigrationAppDependencies`.
    @State private var overlayGate: MBKOverlayGate
    /// Log fetcher lifted to app level so the ZIP cache persists across
    /// column navigations. Initialised from `deps.logFetcher` in `init()`
    /// and threaded into `AppShellView` via `$logFetcher`.
    @State private var logFetcher: LogFetcher

    /// Tracks scene phase so the poller can refresh on activation.
    @Environment(\.scenePhase) private var scenePhase

    /// Initialises shared dependencies before first render.
    ///
    /// Startup ordering (mirrors `AppDelegate+StoreSetup.swift`):
    ///   1. `LocalRunnerStore.configure(viewModel:)` — synchronous, before any await.
    ///   2. `MigrationAppDependencies` is constructed with the single `AppState` instance.
    ///      The windowed app now uses the same `AppState` runtime implementation and
    ///      event-publication chain that the menu-bar interface used.
    init() {
        // ⚠️ MUST be synchronous and before any Task — see AppDelegate+StoreSetup.swift
        // for the ordering rule (fix for issue #1741).
        let state = AppState()

        // Configure LocalRunnerStore before any SwiftUI body access.
        LocalRunnerStore.configure(viewModel: state.runnerState)

        // Capture the already-configured singleton. This is the same store instance
        // AppState will adopt during start() — no duplicate graph.
        let localRunnerStore = LocalRunnerStore.shared

        // Build dependencies with the captured store so the Window body can safely
        // read deps.localRunnerStore without hitting AppState's not-yet-seeded
        // private _localRunnerStore (which would assertion-fail).
        let dependencies = MigrationAppDependencies(
            appState: state,
            localRunnerStore: localRunnerStore
        )

        _appState = State(initialValue: state)
        _deps = State(initialValue: dependencies)
        _overlayGate = State(initialValue: MBKOverlayGate())
        _logFetcher = State(initialValue: state.logFetcher)
    }

    /// The scene graph for the windowed application.
    var body: some Scene {
        Window("RunBot", id: "main") {
            AppShellView(
                localRunnerStore: deps.localRunnerStore,
                settingsDependencies: deps.settingsDependencies,
                logFetcher: $logFetcher
            )
            .environment(deps.runnerState)
            .environment(deps.appState.authentication)
            .environment(overlayGate)
            .task {
                await deps.start()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await deps.refresh() }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
