import RunBotAppCore
import SwiftUI

@main
struct RunBotDesktopApp: App {
    var body: some Scene {
        WindowGroup("RunBot") {
            AppShellView()
        }
        .defaultSize(width: 1_200, height: 760)
    }
}
