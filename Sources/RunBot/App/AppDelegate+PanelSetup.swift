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
// multiplier (AppDelegate.panelHeightMultiplier). Using different multipliers
// creates a gap between what SwiftUI reports as preferredContentSize and what
// MBK allows, forcing SwiftUI to re-layout inside a smaller frame and
// compressing the header. Both caps derive from the same visibleFrame.height —
// keep them in sync. The shared constant AppDelegate.panelHeightMultiplier is
// the single source of truth; do not inline the value at either call site.
//
// SCREEN CAP — WHY NSScreen.main AT LAUNCH IS INTENTIONAL:
// maxHeight is read once from NSScreen.main?.visibleFrame at setupPanel() time
// and passed as a construction parameter to MBKPopoverController. This is the
// designed contract: MBKPopoverController receives a fixed cap at init and uses
// it to clamp the popover height on every open via its internal applyContentSize
// logic. The cap is a hard ceiling that prevents the popover from growing beyond
// the visible screen area — it is NOT a dynamic real-time measurement.
//
// MULTI-SCREEN EDGE CASES ARE OUT OF SCOPE — by design, not by omission:
// RunBot is a status-bar app. The NSStatusItem is anchored to the menu bar,
// which macOS places on exactly one screen at a time (the "main" display, as
// reported by NSScreen.main). The popover always opens directly below that
// status item — it cannot appear on a secondary display. There is therefore
// only ever one relevant screen: NSScreen.main at the time of the read.
// Display topology changes (connect/disconnect, display scaling, resolution
// changes) do not affect this contract — the popover is always on the main
// screen and maxHeight is always derived from that same screen. No dynamic
// per-open re-read or applicationDidChangeScreenParameters wiring is needed.
// ❌ NEVER move this read inside onWillShow or onDidShow — MBKPopoverController
//    requires the cap at construction time, not per-open.

/// Extension owning `MBKPopoverController` construction and lifecycle-callback wiring.
extension AppDelegate {

    // MARK: - Constants

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    /// Maximum popover content width.
    static let maxWidth: CGFloat = 900
    /// Fraction of the visible screen height used as the panel height cap.
    ///
    /// Applied in two places that must stay in sync:
    /// - `setupPanel()` — computes `maxHeight` passed to `MBKPopoverController` at init.
    /// - `PanelMainView.screenScrollMaxHeight` — computes the SwiftUI scroll cap on every call.
    ///
    /// Both derive from `NSScreen.main?.visibleFrame.height`. Using different values at the
    /// two sites creates a gap: MBK clamps the popover at a height SwiftUI didn't expect,
    /// forcing a re-layout that compresses the header (see CAP ALIGNMENT in file header).
    /// ❌ NEVER inline this value at either call site — always reference this constant.
    /// ❌ NEVER change this value without verifying both sites behave correctly.
    static let panelHeightMultiplier: CGFloat = 0.80

    // MARK: - Popover construction

    /// Builds the MBKPopoverController, calls setup(), and wires the three
    /// lifecycle callbacks. Called once from applicationDidFinishLaunching.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        // maxHeight MUST match PanelMainView.screenScrollMaxHeight multiplier.
        // See CAP ALIGNMENT note above. Both sites reference AppDelegate.panelHeightMultiplier —
        // do not inline the value here or in screenScrollMaxHeight.
        //
        // maxHeight is intentionally computed once at launch, not per-open.
        // MBKPopoverController takes this as a constructor cap and does not re-read it.
        // Multi-screen edge cases are out of scope — see SCREEN CAP note above.
        // screenScrollMaxHeight in PanelMainView reads NSScreen.main live on every call
        // and will always be current for the SwiftUI side — the MBK cap is the only
        // value read once at launch, and that is intentional.
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxHeight = visibleHeight * AppDelegate.panelHeightMultiplier
        log("AppDelegate › setupPanel — visibleHeight=\(visibleHeight) maxHeight=\(maxHeight) multiplier=\(AppDelegate.panelHeightMultiplier)")

        let ctrl = MBKPopoverController(
            rootView: wrapEnv(RootPanelView(
                onSelectSettings: { [weak self] in self?.navigateToSettings() },
                onBack: { [weak self] in self?.navigateBack() },
                onStepBack: { [weak self] in self?.navigateBack() }
            )),
            overlayGate: overlayGate,
            symbolName: "menubar.rectangle",
            minWidth: AppDelegate.minWidth,
            maxWidth: AppDelegate.maxWidth,
            maxHeight: maxHeight
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
        // Pre-existing: the old PopoverLifecycleCoordinator had the same contract
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
        // MBKPopoverController exposes setRootView(_:) for adopters that swap
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
        //   • MBK's GeometryReader in wrapped() is attached once at init. Calling
        //     setRootView(_:) replaces the inner view but keeps the same GR wrapper,
        //     which is correct. However, the new inner view loses its .onAppear
        //     trigger for the GR — MBK only sees a size change if SwiftUI reports
        //     one, not a fresh appear. RootPanelView's .id(route) forces a full
        //     re-render on every route change, guaranteeing MBK's GR fires fresh.
        //   • No AnyView boxing on navigation paths — RootPanelView uses concrete
        //     view types in each switch branch.
        //   • AppDelegate stays a pure wiring layer with no view-factory methods.
        //
        // ❌ NEVER add a setRootView(_:) call here for navigation.
        // ❌ NEVER add view factory methods (mainView(), settingsView()) back to AppDelegate.
        // All route changes go through appState.savedNavState only.

        ctrl.setup()
        popoverController = ctrl
        log("AppDelegate › setupPanel — MBKPopoverController setup complete")
    }
}
