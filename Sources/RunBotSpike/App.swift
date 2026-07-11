// App.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// @main entry point. NSApplicationDelegateAdaptor wires NavSheetAppDelegate
// which owns the NSPopover, NSStatusItem, event monitor, and workspace observer.
// The App struct body is intentionally empty — all lifecycle is in the delegate.
//
// NOTE: MenuBarExtra was trialled and reverted. Sheets, file picker anchoring,
// and the status bar arrow indicator all broke. NSPopover remains the approach.
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import SwiftUI

@main
struct NavSheetApp: App {
    @NSApplicationDelegateAdaptor(NavSheetAppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}
