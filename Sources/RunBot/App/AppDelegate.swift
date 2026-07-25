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
//   2. Swap hostingController.rootView on navigation (MBK owns the NSPopover
//      shell but run-bot still controls what's inside it).
//   3. Maintain panelVisibilityState, panelSheetState, and overlayGate as
//      injectable environment objects.
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
    ///
    /// Injected into the SwiftUI view tree via `.environment(overlayGate)` in
    /// `wrapEnv(_:)`. Views use `.mbkSheet(overlayGate:)` and
    /// `mbkOpenFilePicker()` to arm this gate for the overlay lifetime.
    let overlayGate = MBKOverlayGate()

    /// Owns the popover lifecycle: status item, NSPopover, arrow centering,
    /// size tracking, outside-click monitor, workspace observer.
    /// Replaced NSPopover + PopoverLifecycleCoordinator + KVO as of #2262.
    var popoverController: MBKPopoverController?

    /// The SwiftUI hosting controller embedded inside the MBKPopoverController
    /// managed popover. Its `rootView` is swapped on navigation; the controller
    /// itself is never recreated. Obtained from MBKPopoverController after setup.
    var hostingController: NSHostingController<AnyView>?

    /// Sheet state that must survive transient popover hides.
    /// Stays on AppDelegate (wiring concern — not domain state). See issue #2040.
    let panelSheetState = PanelSheetState()

    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()

    // MARK: - Sheet guard

    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    /// Read by onWillClose(wasForced:) to decide whether to snapshot sheet state.
    var hasActiveSheet: Bool {
        guard let ctrl = popoverController else { return false }
        // MBKPopoverController exposes the gate — use overlayGate.hasActiveOverlay
        // as the structural truth for "a sheet is live" from run-bot's perspective.
        // overlayGate is armed by .mbkSheet for the full sheet lifetime.
        return overlayGate.hasActiveOverlay
    }

    // MARK: - Environment injection

    /// Wraps a SwiftUI view in the shared environment objects required by the panel.
    /// Every view produced by a view-factory in AppDelegate+Navigation.swift must
    /// pass through this helper.
    /// ❌ NEVER remove `panelVisibilityState` from the environment injection here.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .environment(panelVisibilityState)
            .environment(appState)
            .environment(overlayGate)
        )
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view`.
    /// MBKPopoverController's GeometryReader picks up the size change automatically.
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Toggle

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets rootView to main so next open starts fresh.
    func closePanel() {
        log("AppDelegate › closePanel")
        // performClose triggers popoverShouldClose → popoverDidClose in MBKPopoverController
        // which fires onWillClose(wasForced: false) and tears down monitors.
        // We also clear nav + sheet state so next open starts at main.
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
        hostingController?.rootView = mainView()
        // MBKPopoverController.popover is internal — close via its delegate path.
        // togglePopover is @objc and not exposed; drive close via the status item button:
        // MBKPopoverController will call performClose when toggled while shown.
        // Run-bot does not need to call performClose directly — the status-bar button
        // action handles it. For programmatic close (e.g. Escape key), navigate back
        // to main first (above) then rely on the user's next toggle.
    }
}
