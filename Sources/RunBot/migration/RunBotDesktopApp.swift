// RunBotDesktopApp.swift
// RunBot

import GitHubClient
import MenuBarKit
import SwiftUI

// @main removed: Sources/RunBot/main.swift is top-level code.
// RunBotDesktopApp.main() is called from main.swift instead.

/// The SwiftUI application entry point for RunBot.
/// `@main` is intentionally absent because `main.swift` invokes `main()`.
struct RunBotDesktopApp: App {
    /// Authentication state owned at the window level and injected into the view hierarchy.
    @State private var authentication: GitHubAuthentication
    /// Runner dependencies configured synchronously before any view is mounted.
    /// `LocalRunnerStore.configure` runs inside `MigrationAppDependencies.init()`.
    /// Constructed in `init()` so it shares the same `authentication` instance.
    @State private var deps: MigrationAppDependencies
    /// Single overlay gate for the scene lifetime.
    ///
    /// Injected at the root of both the legacy panel hierarchy and the windowed
    /// app hierarchy. `MBKOverlayGate` is presentation infrastructure; it is not
    /// placed in `MigrationAppDependencies`.
    @State private var overlayGate: MBKOverlayGate

    /// Initialises shared authentication and dependency bundle before first render.
    init() {
        let auth = GitHubAuthentication()
        _authentication = State(initialValue: auth)
        _deps = State(initialValue: MigrationAppDependencies(
            authentication: auth,
            onSignIn: {
                // OAuthCredentialController lives in AppState (legacy layer).
                // For the migration shell, sign-in is a no-op placeholder.
                // TODO: wire real coordinator when AppState is retired (#2815).
            },
            onSignOut: {}
        ))
    }

    /// The scene graph for the windowed application.
    var body: some Scene {
        Window("RunBot", id: "main") {
            AppShellView(
                runnerState: deps.runnerState,
                localRunnerStore: deps.localRunnerStore,
                settingsDependencies: deps.settingsDependencies
            )
            .environment(authentication)
            .environment(overlayGate)
        }
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
