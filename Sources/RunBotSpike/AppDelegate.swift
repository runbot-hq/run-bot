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
import MenuBarKit
import SwiftUI

/// Application delegate. Creates the shared `AppState` and `MBKOverlayGate`,
/// then hands them to `MBKPopoverController` for the full menu-bar lifecycle.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Application-level state shared across all views via the environment.
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

    // MARK: - Private

    /// App-specific observable state passed into views via SwiftUI environment.
    private let appState = AppState()
    /// Shared overlay gate — MenuBarKit reads and writes this; the spike never touches it directly.
    private let overlayGate = MBKOverlayGate()
    /// The MenuBarKit controller that owns NSPopover, NSStatusItem, and all observers.
    private var popoverController: MBKPopoverController!
}
