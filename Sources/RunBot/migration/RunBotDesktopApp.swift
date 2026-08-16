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
    /// The same `AppState` instance is used by the menu-bar panel (via `AppDelegate`),
    /// ensuring the windowed app and the panel observe the identical `RunnerState`.
    /// When the poller publishes a completed snapshot, all views invalidate reactively.
    @State private var appState = AppState()

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
    ///   2. `MigrationAppDependencies` is constructed with the `AppState` instance
    ///      that will be shared across the menu-bar panel and the windowed app.
    init() {
        // ⚠️ MUST be synchronous and before any Task — see AppDelegate+StoreSetup.swift
        // for the ordering rule (fix for issue #1741).
        let state = AppState()
        _appState = State(initialValue: state)
        LocalRunnerStore.configure(viewModel: state.runnerState)
        _deps = State(initialValue: MigrationAppDependencies(appState: state))
        _overlayGate = State(initialValue: MBKOverlayGate())
        _logFetcher = State(initialValue: state.logFetcher)
    }

    /// The scene graph for the windowed application.
    var body: some Scene {
        Window("RunBot", id: "main") {
            AppShellView(
                runnerState: deps.runnerState,
                localRunnerStore: deps.localRunnerStore,
                settingsDependencies: deps.settingsDependencies,
                logFetcher: $logFetcher
            )
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
