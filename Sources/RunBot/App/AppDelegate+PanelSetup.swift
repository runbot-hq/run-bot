// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// As of #2262 this file owns MBKPopoverController construction and callback
// wiring. NSPopover construction, KVO on preferredContentSize, and
// PopoverLifecycleCoordinator.installMonitors() have been removed —
// MBKPopoverController owns all of that now.
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.

extension AppDelegate {

    // MARK: - Constants

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    /// Maximum popover content width.
    static let maxWidth: CGFloat = 900

    // MARK: - Popover construction

    /// Builds the MBKPopoverController, calls setup(), and wires the three
    /// lifecycle callbacks. Called once from applicationDidFinishLaunching.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        let ctrl = MBKPopoverController(
            rootView: mainView(),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle",
            minWidth: AppDelegate.minWidth,
            maxWidth: AppDelegate.maxWidth
        )

        // onWillShow — fires before popover.show().
        // Restore saved nav state so the correct view is in place before the
        // popover becomes visible. Sheet state is NOT restored here — it needs
        // one render cycle first (see onDidShow).
        ctrl.onWillShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onWillShow")
            if let saved = appState.savedNavState, let view = validatedView(for: saved) {
                navigate(to: view)
            }
        }

        // onDidShow — fires one actor turn after popover.show().
        // Restore sheet state now that the view tree has a window.
        ctrl.onDidShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onDidShow")
            if panelSheetState.wasSheetOpen {
                panelSheetState.isSheetPresented = true
            }
            panelVisibilityState.isOpen = true
            panelVisibilityState.isTransientHide = false
        }

        // onWillClose — fires before any teardown on both normal and force-close paths.
        // wasForced=true: user clicked outside while a sheet was open — snapshot
        //   nav and sheet state so onDidShow can respawn them on next open.
        // wasForced=false: user toggled the icon or pressed Escape — clear state
        //   so next open starts fresh at main.
        ctrl.onWillClose = { [weak self] wasForced in
            guard let self else { return }
            log("AppDelegate › onWillClose wasForced=\(wasForced)")
            if wasForced {
                panelSheetState.captureTransientHideState()
                panelVisibilityState.isTransientHide = true
            } else {
                appState.savedNavState = nil
                panelSheetState.clearRunnerSheet()
                popoverController?.setRootView(mainView())
            }
            panelVisibilityState.isOpen = false
        }

        ctrl.setup()
        popoverController = ctrl
        log("AppDelegate › setupPanel — MBKPopoverController setup complete")
    }
}
