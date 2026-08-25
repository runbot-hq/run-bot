// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// As of #2262 this file owns MBKPanelController construction and callback
// wiring. NSPopover construction, KVO on preferredContentSize, and the old
// lifecycle coordinator have been removed — MBKPanelController owns all of
// that now.
//
// As of the anchored-panel rewrite there is no NSPopover anywhere in the app.
// MenuBarKit owns one borderless NSPanel and its Liquid Glass surface.
// It does not use NSPopover or an anchor arrow.
//
// As of #2264 the root view is RootPanelView — a single persistent view that
// owns all route switching via Group { switch }.id(route). This replaces the
// setRootView() AnyView-swap pattern so MBK re-measures on every route change.
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
// HEIGHT CAP — ONE OWNER, EVALUATED LIVE:
// The 80%-of-visible-height cap is expressed here only as a *fraction*
// (AppDelegate.panelHeightMultiplier) and handed to MenuBarKit. MBK resolves it
// against the live NSScreen visibleFrame on every open and on every
// didChangeScreenParameters notification, applies it as the SwiftUI maxHeight,
// and uses the same number when it computes the window frame. There is no
// second cap on the RunBot side to keep in sync — PanelMainView's old
// screenScrollMaxHeight was deleted with this change.
//
// ❌ NEVER reintroduce a height cap in a RunBot view. Two caps computed from
//    two different reads is precisely what produced the header-shrink and
//    stale-geometry bugs (#2278/#2279): SwiftUI would lay out against one
//    number while the window was clamped to another.
//
// WIDTH — THE OPPOSITE RULE, AND WHY:
// Height is global (it is a property of the screen), so MenuBarKit owns it.
// Width is per-route (the list is wide, Settings is a fixed 480pt), so each
// RunBot view owns its own. MBKPanelController deliberately has no width
// parameter: the range it used to apply in its wrapper was inherited by every
// route, which is what stretched Settings to the list's width on device.
// ❌ NEVER add a width range back to the MBK wrapper.

/// Extension owning `MBKPanelController` construction and lifecycle-callback wiring.
extension AppDelegate {

    // MARK: - Constants

    // WIDTH CONSTANTS LIVE IN `RBMetrics`, NOT HERE.
    // `RBMetrics.panelListMinWidth` / `panelListIdealWidth` / `panelListMaxWidth`
    // are applied by `PanelMainView` to its own root, NOT by MenuBarKit.
    // A width range in MBK's wrapper applies to every route, which stretched
    // the fixed-width Settings screen to the list's width.
    // ❌ NEVER pass a width range to `MBKPanelController` — it no longer has one.

    /// Fraction of the visible screen height the panel content may occupy.
    ///
    /// Handed to `MBKPanelController` as `maxHeightFraction`. MenuBarKit is the only
    /// place this is resolved against a screen, and it resolves it live.
    /// ❌ NEVER derive a second height cap from this value inside a RunBot view.
    static let panelHeightMultiplier: CGFloat = 0.80

    // MARK: - Panel construction

    /// Builds the MBKPanelController, calls setup(), and wires the three
    /// lifecycle callbacks. Called once from applicationDidFinishLaunching.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        // tempHandle is the live, permanent handle. It captures panelController weakly
        // so it is safe to construct before panelController is assigned — by the time
        // any view calls remeasure(), panelController is non-nil (assigned below before
        // any user interaction is possible).
        let tempHandle = PanelControllerHandle(
            remeasure: { [weak self] in
                self?.panelController?.invalidateContentSize()
            }
        )

        let ctrl = MBKPanelController(
            rootView: RootEnvView(
                panelVisibilityState: panelVisibilityState,
                appState: appState,
                overlayGate: overlayGate,
                panelControllerHandle: tempHandle,
                inner: RootPanelView(
                    onSelectSettings: { [weak self] in self?.navigateToSettings() },
                    onBack: { [weak self] in self?.navigateBack() },
                    onStepBack: { [weak self] in self?.navigateBack() }
                )
            ),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle",
            maxHeightFraction: AppDelegate.panelHeightMultiplier
        )

        // No onWillShow callback is required.
        //
        // Navigation state is persistent observable state owned by AppState.
        // Panel dismissal does not clear it, and RootPanelView reads it
        // reactively before the panel becomes visible.

        // onDidShow — fires one actor turn after openPanel().
        // Restore runner sheet state now that the view tree has a window.
        ctrl.onDidShow = { [weak self] in
            guard let self else { return }
            log("AppDelegate › onDidShow")
            panelSheetState.restoreTransientHideStateIfNeeded()
            panelVisibilityState.isOpen = true
            panelVisibilityState.isTransientHide = false

            Task {
                await self.appState.refreshOnPanelShow()
            }
        }

        ctrl.onWillClose = { [weak self] (wasForced: Bool) in
            guard let self else { return }
            log("AppDelegate › onWillClose wasForced=\(wasForced)")
            if wasForced {
                panelSheetState.captureTransientHideState()
                panelVisibilityState.isTransientHide = true
            } else {
                // wasForced=false: normal panel dismissal. Clear transient sheet state
                // through closePanel(), but preserve savedNavState for the next open.
                // This is the shared fix for #2376 (Settings) and #2726 (Step Log).
                closePanel()
            }
            panelVisibilityState.isOpen = false
        }

        ctrl.setup()
        panelController = ctrl
        panelControllerHandle = tempHandle

        log("AppDelegate › setupPanel — MBKPanelController setup complete")
    }
}
