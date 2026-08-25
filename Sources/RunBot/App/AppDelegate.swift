// AppDelegate.swift
// RunBot

import AppKit
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate
//
// As of #2262, NSPopover + PopoverLifecycleCoordinator + KVO are replaced by
// MBKPanelController. As of the anchored-panel rewrite there is no NSPopover
// anywhere in the app: MenuBarKit owns one borderless NSPanel and its Liquid
// Glass surface. It does not use NSPopover or an anchor arrow. The panel
// lifecycle (open, close, force-close, outside-click monitor, workspace
// observer, size tracking) is fully owned by MBKPanelController from
// MenuBarKit.
//
// Run-bot's responsibilities are:
//   1. Wire onWillShow / onDidShow / onWillClose callbacks.
//   2. Maintain panelVisibilityState, panelSheetState, and overlayGate as
//      injectable environment objects.
//   3. Navigation is owned by RootPanelView via appState.savedNavState —
//      no setRootView() calls on navigation paths.
//
// HIDE-WITHOUT-CLOSE:
// The old hidePanel() + hidePopoverWindowsPreservingSheets() path is replaced
// by the MBKPanelController force-close + onWillClose(wasForced:) snapshot
// + onDidShow respawn cycle. When wasForced=true the host snapshots nav and
// sheet state; onDidShow restores them on next open.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is set in onWillClose (false) and onDidShow (true).
// Injected through RootEnvView. Do not remove from the environment chain
// while the MenuBarKit panel shell remains active.
// See PanelContainerView and AppDelegate+PanelSetup for the panel
// visibility-state lifecycle.

/// Environment-injectable handle for remeasuring the panel when SwiftUI content grows.
///
/// `@Observable` is required because SwiftUI's `.environment()` requires the
/// type to conform to `Observable` (as of macOS 26). `MBKPanelController` is
/// a plain `final class` and cannot be made `@Observable` from outside the
/// `MenuBarKit` module, so this wrapper bridges the gap.
///
/// The handle stores an injected closure rather than the panel controller
/// itself. The production closure captures AppDelegate weakly, avoiding a
/// retain cycle through the controller, hosting view, and SwiftUI environment.
@MainActor
@Observable
final class PanelControllerHandle {
    /// Requests `MBKPanelController.invalidateContentSize()` through the
    /// injected closure. Safe while the panel is closed: the measurement is
    /// skipped by `applyMeasuredSize`'s `isShown` guard.
    let remeasure: () -> Void

    /// Creates a handle with the given remeasure closure.
    /// - Parameter remeasure: Closure that invalidates the panel's content size.
    init(remeasure: @escaping () -> Void) {
        self.remeasure = remeasure
    }
}
// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.

/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // NOTE: Properties are `internal` (not `private`) because Swift `private`
    // does not cross file boundaries. AppDelegate+Navigation.swift requires
    // read/write access to all of them.

    // MARK: - AppState

    /// Single coordinator for all domain-level state.
    /// Replaces the scattered property bag — see issue #2040.
    /// ❌ NEVER access domain sub-objects directly on AppDelegate once they
    ///    have been migrated to AppState. Use `appState.x` instead.
    let appState = AppState()

    /// Gate tracking whether a sheet, file picker, or alert is active.
    ///
    /// Injected into the SwiftUI view tree by `RootEnvView`, which is created
    /// in `setupPanel()`. `.mbkSheet` and `.mbkAlert` manage the environment
    /// gate automatically; `mbkOpenFilePicker(overlayGate:)` receives the same
    /// gate explicitly because it is a free function.
    let overlayGate = MBKOverlayGate()

    /// Panel controller handle injected into the SwiftUI environment.
    /// Assigned during `setupPanel()`. The handle itself is constructed before
    /// `panelController` is assigned; its weakly capturing closure resolves the
    /// controller only when a view later requests remeasurement.
    var panelControllerHandle: PanelControllerHandle?

    /// Owns the panel lifecycle: status item, anchored NSPanel, size tracking,
    /// outside-click monitor, and workspace observer.
    /// Replaced NSPopover + KVO as of #2262.
    var panelController: MBKPanelController<RootEnvView>!

    /// Sheet state that must survive transient panel hides.
    /// Stays on AppDelegate (wiring concern — not domain state). See issue #2040.
    let panelSheetState = PanelSheetState()

    /// Shared observable that tracks whether the panel is open.
    /// Injected through RootEnvView. Do not remove from the environment chain
    /// while the MenuBarKit panel shell remains active.
    let panelVisibilityState = PanelVisibilityState()

    // MARK: - Environment injection (removed)
    //
    // wrapEnv() was removed when the panel switched to RootEnvView — a named
    // wrapper that passes environment objects to RootPanelView without AnyView
    // erasure. See RootEnvView.swift.

    // MARK: - Close

    /// Handles cleanup for a normal panel dismissal.
    ///
    /// Preserves `appState.savedNavState` so reopening the panel returns to
    /// the current route. Panel visibility changes must not mutate navigation.
    ///
    /// Clears transient runner-sheet state because the normal close path does
    /// not participate in forced sheet restoration.
    ///
    /// Route reset is owned by `navigateBack()`.
    ///
    /// ⚠️ THIS METHOD INTENTIONALLY DOES NOT DISMISS THE PANEL.
    /// MBKPanelController owns all close paths (status-bar toggle, click-outside,
    /// Escape). This method is called by MBK's onWillClose to reset run-bot state
    /// BEFORE MBK completes its own teardown. Adding a panelController?.close() call
    /// here would re-enter MBK's state machine mid-teardown and cause double-close or
    /// missed onWillClose callbacks.
    ///
    /// CALL SITE AUDIT (keep current):
    ///   • AppDelegate+PanelSetup onWillClose(wasForced: false) — the only caller.
    ///   • navigateBack() does NOT call this — back-nav changes route, not close state.
    ///   • No keyboard shortcut or Escape handler routes through this method.
    /// If you add a call site that expects the panel to visually close, wire
    /// panelController?.close() there directly instead of routing through here.
    ///
    /// ❌ NEVER add panelController?.close() here.
    /// ❌ NEVER clear savedNavState here — panel visibility must not alter navigation.
    ///    Preserving savedNavState is the fix for both #2376 (Settings) and #2726 (Step Log).
    func closePanel() {
        log("AppDelegate › closePanel")
        panelSheetState.clearRunnerSheet()
    }
}
