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
// As of #2264 the root view is RootPanelView — a single persistent view that
// owns all route switching via Group { switch }.id(route). This replaces the
// setRootView() AnyView-swap pattern so MBK's GeometryReader always fires
// fresh on every route change.
//
// SHEET RESPAWN MODEL:
// PanelSheetState tracks editingRunner (the runner whose detail sheet is open).
// On force-close (wasForced=true), captureTransientHideState() snapshots
// editingRunner into runnerSheetSnapshot. On next open, onDidShow calls
// restoreTransientHideStateIfNeeded() which copies the snapshot back to
// editingRunner — SwiftUI sees the binding and re-presents the sheet.
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// CAP ALIGNMENT (ref header-shrink investigation):
// maxHeight and PanelMainView.screenScrollMaxHeight MUST use the same
// multiplier (0.80). Using different multipliers creates a gap between
// what SwiftUI reports as preferredContentSize and what MBK allows,
// forcing SwiftUI to re-layout inside a smaller frame and compressing
// the header. Both caps derive from the same visibleFrame.height — keep
// them in sync.

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

        // maxHeight MUST match PanelMainView.screenScrollMaxHeight multiplier (0.80).
        // See CAP ALIGNMENT note above. Do NOT change this to a different multiplier
        // without also changing screenScrollMaxHeight in PanelMainView.
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxHeight = visibleHeight * 0.80
        log("AppDelegate › setupPanel — visibleHeight=\(visibleHeight) maxHeight=\(maxHeight) multiplier=0.80")

        let ctrl = MBKPopoverController(
            rootView: wrapEnv(RootPanelView(
                onSelectSettings: { [weak self] in self?.navigateToSettings() },
                onBack:           { [weak self] in self?.navigateBack() },
                onStepBack:       { [weak self] in self?.navigateBack() }
            )),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle",
            minWidth: AppDelegate.minWidth,
            maxWidth: AppDelegate.maxWidth,
            maxHeight: maxHeight
        )

        // onWillShow — fires before popover.show().
        // Nav state is already live in appState.savedNavState.
        // RootPanelView reads it directly — nothing to do here.
        ctrl.onWillShow = {
            log("AppDelegate › onWillShow")
        }

        // onDidShow — fires one actor turn after popover.show().
        // Restore runner sheet state now that the view tree has a window.
        ctrl.onDidShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onDidShow")
            panelSheetState.restoreTransientHideStateIfNeeded()
            panelVisibilityState.isOpen = true
            panelVisibilityState.isTransientHide = false
        }

        // onWillClose — fires before any teardown on both normal and force-close paths.
        ctrl.onWillClose = { [weak self] wasForced in
            guard let self else { return }
            log("AppDelegate › onWillClose wasForced=\(wasForced)")
            if wasForced {
                panelSheetState.captureTransientHideState()
                panelVisibilityState.isTransientHide = true
            } else {
                appState.savedNavState = nil
                panelSheetState.clearRunnerSheet()
            }
            panelVisibilityState.isOpen = false
        }

        ctrl.setup()
        popoverController = ctrl
        log("AppDelegate › setupPanel — MBKPopoverController setup complete")
    }
}
