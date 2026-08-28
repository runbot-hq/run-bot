// RunBotApp.swift
// RunBot

import GitHubClient
import RunBotCore
import SwiftUI

// @main removed: Sources/RunBot/App/main.swift is top-level code.
// RunBotApp.main() is called from main.swift instead.

/// The SwiftUI application entry point for RunBot.
/// `@main` is intentionally absent because `main.swift` invokes `main()`.
struct RunBotApp: App {
    /// Authentication state owned at the window level and injected into the view hierarchy.
    @State private var authentication: GitHubAuthentication
    /// Long-lived domain runtime configured synchronously before any view is mounted.
    /// `LocalRunnerStore.configure` runs inside `RunBotRuntime.init()`.
    /// Constructed in `init()` so it shares the same `authentication` instance.
    @State private var runtime: RunBotRuntime
    /// App-owned log fetcher so the ZIP cache survives navigation and view
    /// remounts. Created here (not in `RunBotRuntime`) because its
    /// lifetime is tied to the scene, threaded into `AppNavigationSplitView` via
    /// `$logFetcher`.
    @State private var logFetcher: LogFetcher

    /// Initialises shared authentication and the domain runtime before first render.
    init() {
        let auth = GitHubAuthentication()
        _authentication = State(initialValue: auth)
        _runtime = State(initialValue: RunBotRuntime(
            authentication: auth,
            onSignIn: {
                // OAuthCredentialController lives in GitHubClient; sign-in UI is
                // presented by AuthenticationSection inside the settings detail view.
            },
            onSignOut: {
                // Intentionally empty: sign-out UI is handled by
                // AuthenticationSection; no app-level teardown is required.
            }
        ))
        _logFetcher = State(initialValue: LogFetcher())
    }

    /// The scene graph for the windowed application.
    var body: some Scene {
        Window("RunBot", id: "main") {
            AppNavigationSplitView(
                runnerState: runtime.runnerState,
                localRunnerStore: runtime.localRunnerStore,
                settingsDependencies: runtime.settingsDependencies,
                logFetcher: $logFetcher
            )
            .environment(authentication)
            .task {
                await runtime.start()
            }
            .onOpenURL { url in
                guard
                    url.scheme == GitHubConstants.oauthScheme,
                    url.host == GitHubConstants.oauthHost
                else { return }
                runtime.handleOAuthCallback(url)
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
