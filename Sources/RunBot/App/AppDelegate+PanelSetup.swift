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

        // maxHeight: cap at 85 % of visible screen height, consistent with the
        // screenScrollMaxHeight cap inside PanelMainView's ScrollView.
        // Prevents the popover from growing off-screen on small or split displays.
        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) * 0.85

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
        // Restore saved nav state so the correct route is active before the
        // popover becomes visible. Route is now driven purely by
        // appState.savedNavState — no setRootView() call needed.
        ctrl.onWillShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onWillShow")
            // Nav state is already live in appState.savedNavState.
            // RootPanelView reads it directly — nothing to do here.
        }

        // onDidShow — fires one actor turn after popover.show().
        // Restore runner sheet state now that the view tree has a window.
        // restoreTransientHideStateIfNeeded() copies runnerSheetSnapshot →
        // editingRunner; SwiftUI sees the binding and re-presents the sheet.
        ctrl.onDidShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onDidShow")
            panelSheetState.restoreTransientHideStateIfNeeded()
            panelVisibilityState.isOpen = true
            panelVisibilityState.isTransientHide = false
        }

        // onWillClose — fires before any teardown on both normal and force-close paths.
        // wasForced=true: user clicked outside while a sheet was open — snapshot
        //   editingRunner so onDidShow can respawn the sheet on next open.
        // wasForced=false: user toggled the icon or pressed Escape — clear state
        //   so next open starts fresh at main. RootPanelView reacts to
        //   savedNavState = nil automatically; no setRootView() needed.
        ctrl.onWillClose = { [weak self] wasForced in
            guard let self else { return }
            log("AppDelegate › onWillClose wasForced=\(wasForced)")
            if wasForced {
                // Snapshot before teardown: editingRunner is still set.
                panelSheetState.captureTransientHideState()
                panelVisibilityState.isTransientHide = true
            } else {
                appState.savedNavState = nil
                panelSheetState.clearRunnerSheet()
                // ✅ No setRootView() needed — RootPanelView reacts to nil savedNavState.
            }
            panelVisibilityState.isOpen = false
        }

        ctrl.setup()
        popoverController = ctrl
        log("AppDelegate › setupPanel — MBKPopoverController setup complete")
    }
}
