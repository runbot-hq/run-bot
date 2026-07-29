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
// MenuBarKit owns one borderless NSPanel and draws the bubble and arrow itself.
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
    // `RBMetrics.panelListMinWidth` / `panelListMaxWidth` are applied by
    // `PanelMainView` to its own root, NOT by MenuBarKit. A width range in MBK's
    // wrapper applies to every route, which stretched the fixed-width Settings
    // screen (480pt) to the list's width.
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

        let ctrl = MBKPanelController(
            rootView: wrapEnv(RootPanelView(
                onSelectSettings: { [weak self] in self?.navigateToSettings() },
                onBack: { [weak self] in self?.navigateBack() },
                onStepBack: { [weak self] in self?.navigateBack() }
            )),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle",
            maxHeightFraction: AppDelegate.panelHeightMultiplier
        )

        // onWillShow is intentionally empty / commented out.
        //
        // WHY nav state does not need to be restored here:
        // appState.savedNavState is persistent @Observable state — it is never cleared
        // on open, only on explicit back-navigation or onWillClose(wasForced: false).
        // RootPanelView reads it directly and reactively; by the time onWillShow fires
        // the SwiftUI tree is already rendering the correct route. There is nothing to do.
        //
        // Other candidates considered for this callback (auth token pre-flight, stale-job
        // guard restoration) were deferred — see the commented-out block below for context.
        // Do not remove; restore and expand once onWillShow responsibilities are decided.
        // ctrl.onWillShow = {
        //     log("AppDelegate › onWillShow")
        // }

        // onDidShow — fires one actor turn after openPanel().
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
        //
        // ⚠️ KNOWN LIMITATION — isTransientHide state leak:
        // When wasForced=true, panelVisibilityState.isTransientHide is set to true here
        // and is only cleared in onDidShow. If the user force-closes (clicks outside
        // while a sheet is open) and then NEVER reopens the panel, isTransientHide
        // remains true. On a subsequent normal open after a cold relaunch this is
        // harmless (the app relaunches with fresh state). Within the same session,
        // onDidShow always fires on the next open and clears the flag — so the leak
        // window is: force-close → quit without reopening → (no consequence, app exits).
        // The only risky path would be if MBK fired onWillClose(wasForced:true) without
        // a subsequent onDidShow within the same session, which would require MBK to
        // suppress its own open callback — not a documented MBK behaviour.
        // Pre-existing: the old lifecycle coordinator had the same contract
        // (preservedSheetWindowHide was cleared by openPanel(), not by a separate guard).
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

        // setRootView(_:) is intentionally NOT called — ever.
        //
        // MBKPanelController exposes setRootView(_:) for adopters that swap
        // top-level views on navigation (AnyView-swap pattern). RunBot does not
        // use this path.
        //
        // Instead, navigation is owned by RootPanelView via appState.savedNavState:
        //   • A single persistent SwiftUI root (RootPanelView) is passed at init
        //     time and never replaced.
        //   • Route changes are pure state mutations — RootPanelView switches
        //     branches internally via Group { switch }.id(route).
        //
        // WHY this is better than setRootView(_:) for RunBot:
        //   • MBK measures the hosted content's intrinsic size. RootPanelView's
        //     .id(route) forces a full re-render on every route change, which
        //     invalidates that intrinsic size and drives a fresh frame — without
        //     rebuilding the hosting view.
        //   • No AnyView boxing on navigation paths — RootPanelView uses concrete
        //     view types in each switch branch.
        //   • AppDelegate stays a pure wiring layer with no view-factory methods.
        //
        // ❌ NEVER add a setRootView(_:) call here for navigation.
        // ❌ NEVER add view factory methods (mainView(), settingsView()) back to AppDelegate.
        // All route changes go through appState.savedNavState only.

        ctrl.setup()
        panelController = ctrl
        log("AppDelegate › setupPanel — MBKPanelController setup complete")
    }
}
