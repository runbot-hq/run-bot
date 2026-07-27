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

/// Extension owning `MBKPopoverController` construction and lifecycle-callback wiring.
extension AppDelegate {

    // MARK: - Popover construction

    /// Builds the MBKPopoverController, calls setup(), and wires the three
    /// lifecycle callbacks. Called once from applicationDidFinishLaunching.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        let ctrl = MBKPopoverController(
            rootView: wrapEnv(RootPanelView(
                onSelectSettings: { [weak self] in self?.navigateToSettings() },
                onBack: { [weak self] in self?.navigateBack() },
                onStepBack: { [weak self] in self?.navigateBack() }
            )),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle"
        )

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
        // wasForced=true: user clicked outside while a sheet was open — snapshot
        //   nav and sheet state so onDidShow can respawn them on next open.
        // wasForced=false: user toggled the icon or pressed Escape — delegate to
        //   closePanel() which is the canonical normal-close state-reset path.
        //
        // ⚠️ ORDERING INVARIANT (load-bearing — do not reorder) — wasForced=true PATH ONLY:
        // On the wasForced=true path, isTransientHide MUST be set to true BEFORE
        // isOpen is set to false. PanelContainerView.onChange(of: panelVisibilityState.isOpen)
        // fires synchronously when isOpen changes; if isTransientHide is not already true
        // at that point, the dim-overlay animation replays incorrectly on the next restore.
        // The current ordering (captureTransientHideState → isTransientHide = true →
        // [end of if-block] → isOpen = false) preserves this invariant.
        //
        // On the wasForced=false path, isTransientHide is intentionally NOT set — it
        // remains false. PanelContainerView.onChange(of: isOpen) fires with
        // isTransientHide == false, which is the correct signal for a normal close: the
        // dim overlay animates out as expected. Setting isTransientHide = true on this
        // path would suppress the animation and leave the flag permanently dirty.
        // Both paths write isOpen = false unconditionally at the end of the closure —
        // the ordering constraint above applies only to the wasForced=true branch.
        ctrl.onWillClose = { [weak self] wasForced in
            guard let self else { return }
            log("AppDelegate › onWillClose wasForced=\(wasForced)")
            if wasForced {
                panelSheetState.captureTransientHideState()
                panelVisibilityState.isTransientHide = true
            } else {
                closePanel()
            }
            panelVisibilityState.isOpen = false
        }

        ctrl.setup()
        popoverController = ctrl
        log("AppDelegate › setupPanel — MBKPopoverController setup complete")
    }
}
