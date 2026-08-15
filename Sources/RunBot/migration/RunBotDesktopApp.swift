import SwiftUI

// @main removed: Sources/RunBot/main.swift is top-level code.
// RunBotDesktopApp.main() is called from main.swift instead.
struct RunBotDesktopApp: App {
    var body: some Scene {
        WindowGroup("RunBot") {
            AppShellView()
        }
        .defaultSize(width: 1_200, height: 760)
    }
}
