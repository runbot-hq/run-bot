// App.swift
// MenuBarKitExample
//
// Thin @main entry point. All popover/sheet/monitor lifecycle is owned by
// MenuBarKit (MBKPopoverController). This file has one job: wire AppDelegate.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import SwiftUI

/// The SwiftUI App entry point. Wires `AppDelegate` via `@NSApplicationDelegateAdaptor`.
@main
struct MenuBarKitExampleApp: App {
    /// The application delegate that owns the MenuBarKit popover controller.
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    /// A minimal scene required by SwiftUI's App protocol; all real UI lives in the popover.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
