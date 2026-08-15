// RunBotDesktopApp.swift
// RunBot

import GitHubClient
import SwiftUI

// @main removed: Sources/RunBot/main.swift is top-level code.
// RunBotDesktopApp.main() is called from main.swift instead.

/// The SwiftUI application entry point for RunBot.
/// `@main` is intentionally absent because `main.swift` invokes `main()`.
struct RunBotDesktopApp: App {
    /// Authentication state owned at the window level and injected into the view hierarchy.
    @State private var authentication = GitHubAuthentication()
    /// Runner dependencies configured synchronously before any view is mounted.
    /// `LocalRunnerStore.configure` runs inside `MigrationAppDependencies.init()`.
    @State private var deps = MigrationAppDependencies()

    /// The scene graph for the windowed application.
    var body: some Scene {
        Window("RunBot", id: "main") {
            AppShellView(
                runnerState: deps.runnerState,
                localRunnerStore: deps.localRunnerStore
            )
            .environment(authentication)
        }
        .defaultSize(width: 1_200, height: 760)
        .windowResizability(.contentMinSize)
    }
}
