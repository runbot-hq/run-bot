// RunBotDesktopApp.swift
// RunBot

import GitHubClient
import RunBotCore
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
    /// App-owned log fetcher so the ZIP cache survives navigation and view
    /// remounts. Created here (not in `MigrationAppDependencies`) because its
    /// lifetime is tied to the scene, threaded into `AppShellView` via
    /// `$logFetcher`.
    @State private var logFetcher: LogFetcher

    /// Initialises shared authentication and dependency bundle before first render.
    init() {
        let auth = GitHubAuthentication()
        _authentication = State(initialValue: auth)
        _deps = State(initialValue: MigrationAppDependencies(
            authentication: auth,
            onSignIn: {
                // OAuthCredentialController lives in GitHubClient; sign-in UI is
                // presented by AuthenticationSection inside the settings detail view.
            },
            onSignOut: {}
        ))
        _logFetcher = State(initialValue: LogFetcher())
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
            .environment(authentication)
            .task {
                await deps.start()
            }
            .onOpenURL { url in
                guard
                    url.scheme == GitHubConstants.oauthScheme,
                    url.host == GitHubConstants.oauthHost
                else { return }
                deps.handleOAuthCallback(url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
