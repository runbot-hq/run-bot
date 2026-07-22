// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction and subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// WHY NSPopover (#1017):
// NSPopover uses NSPopoverWindowFrame whose chrome is drawn by the
// window-server compositor. Rounded corners survive SwiftUI .sheet
// attachment natively — no CALayer manipulation required or desired.
//
// POPOVER BEHAVIOR: .applicationDefined (#1195)
// behavior = .applicationDefined is set at setupPanel() AND re-asserted
// immediately before every popover.show() call in openPanel(). AppKit latches
// the behavior at show-time; failing to re-assert it caused silent reversion
// to .transient between sessions (Attempt 8 root cause).
//
// .transient was tried (Attempt 2) and failed — AppKit's .transient dismiss
// fires on ANY outside interaction, including clicks inside NSOpenPanel.
// .transient does NOT have special awareness of system panels.
//
// OUTSIDE-CLICK / APP-SWITCH HIDE (#1195 — what actually works):
// Both are handled by a manual NSEvent global monitor (outsideClickMonitor)
// and an NSWorkspace observer (workspaceObserver), both installed by openPanel()
// and torn down by tearDownOpenState().
//
// The key guard in outsideClickMonitor is:
//
//   guard !self.hasActiveSheet else { return }   // ← THE FIX
//
// NSOpenPanel is attached to the popover window via beginSheetModal(for:),
// making it appear in popoverWindow.sheets. While any sheet is attached,
// hasActiveSheet is true and every outside click is ignored — the popover
// cannot be dismissed by a click that lands inside the NSOpenPanel.
//
// popoverShouldClose always returns true — AppKit is never blocked here.
// All dismiss control goes through the manual monitor.
//
// ❌ NEVER use picker.begin { } (free-floating NSOpenPanel). It does NOT
//    appear in popoverWindow.sheets and the hasActiveSheet guard is blind to it.
// ❌ NEVER use runModal() for NSOpenPanel. Same reason as above.
// ✅ ALWAYS use picker.beginSheetModal(for: popoverWindow) so the picker
//    attaches as a child sheet and hasActiveSheet fires correctly.
//
// SHEET HANDLING:
// SwiftUI .sheet() attaches as a child NSWindow to the popover's backing
// window. Two problems arise:
//
// 1. NO DIM: NSPopoverWindowFrame does not participate in AppKit's standard
//    modal sheet dimming. Fix: PanelContainerView polls NSWindow.sheets and
//    overlays Color.black.opacity(0.35) when a sheet is present.
//
// 2. OUTSIDE-TAP BEHAVIOUR DURING SHEET:
//    Tapping outside while a sheet is open hides the popover so the user
//    can interact with other apps, but savedNavState preserves where they
//    were so re-opening restores context.
//
//    Implementation:
//    - popoverShouldClose always returns true. AppKit is never blocked.
//    - popoverDidClose saves hasActiveSheet state before state clears.
//    - openPanel restores via savedNavState.
//    - Sheet NSWindows are children of the popover window; AppKit removes
//      them when the popover closes. SwiftUI re-presents on re-open if the
//      binding is still true. savedNavState = .settings ensures navigation.
//
// ❌ NEVER add dismissSheets() to hidePanel() — it destroys sheet @State.
// ❌ NEVER reset hostingController.rootView inside hidePanel().
//
// SIZE NOTE (rewritten — matches runbot-hq/MenuBarKit PR #6 exactly):
// popover.contentSize is now updated via SwiftUI reporting its OWN size
// directly, not via KVO on NSHostingController.preferredContentSize.
//
// PopoverController.swift's own CRITICAL GOTCHA comment: "SIZE OBSERVATION:
// observe from SwiftUI only. NSView KVO / frameDidChangeNotification
// silently fail inside NSPopover. Use GeometryReader + onChange." KVO on
// preferredContentSize was exactly this unreliable path — AppKit re-deriving
// a size from SwiftUI's layout, rather than SwiftUI reporting it directly —
// and was especially unreliable for WIDTH changes, which is consistent with
// this app's own history of Settings-view sizing regressions.
//
// `sizingOptions` is left at its default (`[]`) — NOT set to
// `.preferredContentSize` — because nothing reads `preferredContentSize`
// anymore; there is no reason to ask AppKit to compute it.
//
// The replacement mechanism: PanelContainerView (see PanelContainerView.swift
// SIZE REPORTING note) wraps its content in a `background(GeometryReader{...})`
// and calls `onSizeChange(geo.size)` on `.onAppear` and `.onChange(of: geo.size)`.
// `mainView()`/`settingsView()` in AppDelegate+Navigation.swift wire that
// callback to `resizeAndRepositionPanel(preferredSize:)` (AppDelegate.swift),
// which is the ONLY thing that mutates `popover.contentSize` — exactly one
// size-reporting path, matching MenuBarKit PR #6's `applyContentSize`.
//
// A prior attempt to remove `sizingOptions`/KVO here was reverted because it
// removed the ONLY size-reporting mechanism without installing a replacement,
// leaving the popover permanently stuck at its initial contentSize. This is
// not that: KVO is removed AND the GeometryReader replacement lands in the
// SAME change series (PanelContainerView.swift + AppDelegate+Navigation.swift
// + AppDelegate.swift, all in this commit series) so there is no gap where
// sizing has no driver at all.
//
// The side-jump/reposition bug is NOT caused by the size-observation
// mechanism — it is caused by resizeAndRepositionPanel() mixing chrome and
// content coordinate spaces when correcting the origin after AppKit's
// default grow-from-bottom-left resize. That fix (reading window.frame
// BEFORE mutating contentSize, then shifting origin by the exact
// (newSize - oldSize) delta) is unchanged by this commit — see
// resizeAndRepositionPanel(preferredSize:) in AppDelegate.swift.
// ❌ NEVER call popover.show() again on resize.

/// Extension responsible for NSPopover construction and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires async
    /// subscriptions. Size is driven by SwiftUI reporting its own size via
    /// `PanelContainerView.onSizeChange` — see SIZE NOTE above. No KVO here.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        // sizingOptions left at default ([]) -- nothing reads preferredContentSize
        // anymore. See SIZE NOTE above.
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        // .applicationDefined: popoverShouldClose(_:) is consulted on every
        // is true, keeping the popover alive when user clicks in NSOpenPanel.
        // Manual NSEvent monitor + NSWorkspace observer handle hide-on-app-switch.
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — popover created, wiring subscriptions")
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    /// Always returns `true` — AppKit is never blocked from closing the popover here.
    ///
    /// All dismiss control is handled by the manual `outsideClickMonitor` and
    /// `workspaceObserver` in `openPanel()`. Those monitors guard against
    /// NSOpenPanel clicks via `hasActiveSheet` (the panel is attached as a sheet
    /// via `beginSheetModal`, so `popoverWindow.sheets` is non-empty while it
    /// is open). There is no need to block AppKit here.
    ///
    /// `isFilePickerActive` is intentionally NOT used here. Earlier attempts
    /// (Attempts 4–6, see `docs/graveyard.md`) tried gating this method on a
    /// boolean flag, but `beginSheetModal` makes that unnecessary: the sheet
    /// attachment is structural truth visible via `popoverWindow.sheets`, which
    /// `hasActiveSheet` reads directly. The flag approach was removed in favour
    /// of that structural check.
    ///
    /// See the OUTSIDE-CLICK / APP-SWITCH HIDE comment block above for the full
    /// mechanism. See `docs/graveyard.md` for the history of approaches that
    /// tried to gate this method and why they all failed.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        #if DEBUG
        log("AppDelegate › popoverShouldClose — CALLED behavior=\(popover.behavior.rawValue) panelIsOpen=\(panelIsOpen) caller=\(Thread.callStackSymbols[1])")
        #endif
        log("AppDelegate › popoverShouldClose — returning true (allowing close)")
        return true
    }

    /// Syncs internal state after the popover closes for any reason.
    /// Primary purpose: safety net for OS-initiated closes (e.g. user clicks outside).
    /// When `closePanel()` or `hidePanel()` drives the close, they call
    /// `tearDownOpenState()` directly — by the time this fires, `panelIsOpen`
    /// is already `false` and the guard exits immediately.
    public func popoverDidClose(_ _: Notification) {
        #if DEBUG
        // swiftlint:disable:next line_length
        log("AppDelegate › popoverDidClose — panelIsOpen=\(panelIsOpen) behavior=\((NSApp.delegate as? AppDelegate)?.popover?.behavior.rawValue ?? -1) stack=\(Thread.callStackSymbols.prefix(5).joined(separator: "||"))")
        #endif
        guard panelIsOpen else {
            log("AppDelegate › popoverDidClose — guard exit (panelIsOpen already false)")
            return
        }
        log("AppDelegate › popoverDidClose — calling tearDownOpenState (unexpected OS-driven close)")
        tearDownOpenState()
    }
}
