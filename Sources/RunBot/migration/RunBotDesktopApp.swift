// RunBotDesktopApp.swift
// RunBot

import SwiftUI

// @main removed: Sources/RunBot/main.swift is top-level code.
// RunBotDesktopApp.main() is called from main.swift instead.

/// The SwiftUI application entry type for the new windowed RunBot shell.
/// Migration step 1 (#2797/#2799). `@main` is intentionally absent —
/// `main.swift` top-level code calls `RunBotDesktopApp.main()` directly.
struct RunBotDesktopApp: App {
    /// The scene graph for the windowed application.
    var body: some Scene {
        WindowGroup("RunBot") {
            AppShellView()
        }
        .defaultSize(width: 1_200, height: 760)
    }
}
