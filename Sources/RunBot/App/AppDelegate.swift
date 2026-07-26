// AppDelegate.swift
// RunBot

import AppKit
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - AppDelegate
//
// As of #2262, NSPopover + PopoverLifecycleCoordinator + KVO are replaced by
// MBKPopoverController. The popover lifecycle (open, close, force-close,
// outside-click monitor, workspace observer, arrow centering, size tracking)
// is now fully owned by MBKPopoverController from MenuBarKit.
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
// by the MBKPopoverController force-close + onWillClose(wasForced:) snapshot
// + onDidShow respawn cycle. When wasForced=true the host snapshots nav and
// sheet state; onDidShow restores them on next open.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is set in onWillClose (false) and onDidShow (true).
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// See ARCHITECTURE.md §panelVisibilityState.

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

    /// Gate that tracks whether a sheet or file-picker overlay is active.
    /// Injected into the SwiftUI view tree via `.environment(overlayGate)` in
    /// `wrapEnv(_:)`. Views use `.mbkSheet(overlayGate:)` and
    /// `mbkOpenFilePicker()` to arm this gate for the overlay lifetime.
    let overlayGate = MBKOverlayGate()

    /// Owns the popover lifecycle: status item, NSPopover, arrow centering,
    /// size tracking, outside-click monitor, workspace observer.
    /// Replaced NSPopover + PopoverLifecycleCoordinator + KVO as of #2262.
    var popoverController: MBKPopoverController?

    /// Sheet state that must survive transient popover hides.
    /// Stays on AppDelegate (wiring concern — not domain state). See issue #2040.
    let panelSheetState = PanelSheetState()

    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()

    // MARK: - Environment injection

    /// Wraps a SwiftUI view in the shared environment objects required by the panel.
    /// Every view produced by a view-factory in AppDelegate+Navigation.swift must
    /// pass through this helper.
    /// ❌ NEVER remove `panelVisibilityState` from the environment injection here.
    /// `PanelContainerView` and its dim overlay observe this object;
    /// removing it causes a runtime crash on sheet dismissal.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .environment(panelVisibilityState)
            .environment(appState)
            .environment(overlayGate)
        )
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Close

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Clears nav + sheet state — RootPanelView reacts to savedNavState = nil
    /// and routes to the main branch automatically. No setRootView() needed.
    /// MBKPopoverController drives the actual close via its status-bar button
    /// toggle — this method resets run-bot state ahead of that.
    func closePanel() {
        log("AppDelegate › closePanel")
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
    }
}
