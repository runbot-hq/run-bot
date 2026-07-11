// AppDelegate.swift
// RunBotSpike
//
// Thin consumer of MenuBarKit. Owns only:
//   - AppState (app-specific data)
//   - MBKOverlayGate (passed into MenuBarKit)
//   - MBKPopoverController (configured with root view + gate)
//
// Nothing about popover lifecycle, monitors, or window management lives here.

import AppKit
import SwiftUI
import MenuBarKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        popoverController = MBKPopoverController(
            rootView: RootView()
                .environment(appState)
                .environment(overlayGate),
            overlayGate: overlayGate,
            symbolName: "flask.fill"
        )
        popoverController.setup()
    }
}
