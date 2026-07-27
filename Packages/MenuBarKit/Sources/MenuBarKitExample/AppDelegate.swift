// AppDelegate.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        mbkLog("AppDelegate", "applicationDidFinishLaunching")
        popoverController = MBKPopoverController(
            rootView: RootView()
                .environment(appState)
                .environment(overlayGate),
            overlayGate: overlayGate,
            symbolName: "flask.fill"
        )
        mbkLog("AppDelegate", "popoverController created")
        popoverController.setup()

        popoverController.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            mbkLog("AppDelegate", "onWillShow -- restoring route=\(snap.route)")
            appState.route = snap.route
        }

        popoverController.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            mbkLog("AppDelegate", "onDidShow -- restoring isSheetPresented=\(snap.isSheetPresented)")
            lastSession = AppState.SessionSnapshot(route: snap.route, isSheetPresented: false)
            appState.isSheetPresented = snap.isSheetPresented
        }

        popoverController.onWillClose = { [weak self] wasForced in
            guard let self else { return }
            let snap = appState.saveSnapshot()
            lastSession = snap
            mbkLog("AppDelegate", "onWillClose wasForced=\(wasForced) -- session saved: route=\(snap.route) sheet=\(snap.isSheetPresented)")
            if wasForced {
                // Reset live sheet state so SwiftUI tears down the sheet window
                // before forceClose() closes the child window and performClose fires.
                appState.isSheetPresented = false
            }
        }

        mbkLog("AppDelegate", "setup complete")
    }

    private let appState = AppState()
    private let overlayGate = MBKOverlayGate()
    private var popoverController: MBKPopoverController!
    private var lastSession: AppState.SessionSnapshot?
}
