// AppDelegate.swift
// MenuBarKitExample

import AppKit
import MenuBarKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        mbkLog("AppDelegate", "applicationDidFinishLaunching")
        panelController = MBKPanelController(
            // Width is the adopter's business — MBKPanelController has no width
            // parameter, so the range lives on the root view here.
            rootView: AnyView(
                RootView()
                    .frame(minWidth: 200, maxWidth: 480)
                    .environment(appState)
                    .environment(overlayGate)
            ),
            overlayGate: overlayGate,
            symbolName: "flask.fill",
            maxHeightFraction: 0.8
        )
        mbkLog("AppDelegate", "panelController created")
        panelController?.setup()

        panelController?.onWillShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            mbkLog("AppDelegate", "onWillShow -- restoring route=\(snap.route)")
            appState.route = snap.route
        }

        panelController?.onDidShow = { [weak self] in
            guard let self, let snap = lastSession else { return }
            mbkLog("AppDelegate", "onDidShow -- restoring isSheetPresented=\(snap.isSheetPresented)")
            lastSession = AppState.SessionSnapshot(route: snap.route, isSheetPresented: false)
            appState.isSheetPresented = snap.isSheetPresented
        }

        panelController?.onWillClose = { [weak self] wasForced in
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
    private var panelController: MBKPanelController<AnyView>?
    private var lastSession: AppState.SessionSnapshot?
}
