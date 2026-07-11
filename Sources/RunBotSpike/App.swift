// App.swift
// RunBotSpike
//
// Thin @main entry point. All popover/sheet/monitor lifecycle is owned by
// MenuBarKit (MBKPopoverController). This file has one job: wire AppDelegate.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import SwiftUI

@main
struct RunBotSpikeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
