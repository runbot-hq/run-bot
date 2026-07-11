// App.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Entry point. Swapped from NSPopover + NSApplicationDelegateAdaptor
// to MenuBarExtra (.window style) on macOS 26.
//
// What this removes vs the NSPopover approach:
//   - NSStatusItem / NSPopover setup
//   - NSApp.activate(ignoringOtherApps: true) call
//   - NSEvent global monitor for outside clicks
//   - NSWorkspace.didActivateApplicationNotification observer
//   - button.isHighlighted manual tracking
//
// What stays (still required even with MenuBarExtra):
//   - AnchoredSheet / addChildWindow — sheet anchoring is NOT native
//   - overlayCount guard in popoverShouldClose equivalent
//   - NSOpenPanel.beginSheetModal — .fileImporter not yet validated
//
// REQUIREMENTS: macOS 26+, Swift 6.2

import AppKit
import SwiftUI

@main
struct NavSheetApp: App {
    @State private var appState = NavSheetAppState()

    var body: some Scene {
        MenuBarExtra {
            NavSheetRootView(
                onPickFolder: { /* wired below via AppState */ },
                onPickFolderFromSheet: { /* wired below via AppState */ }
            )
            .environment(appState)
        } label: {
            Text("Flask")
        }
        .menuBarExtraStyle(.window)
    }
}
