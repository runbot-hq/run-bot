// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and
// subscriptions that drive icon/store updates.
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
// SIZE NOTE:
// popover.contentSize is updated (both width AND height) via KVO on
// NSHostingController.preferredContentSize. Updating contentSize resizes
// the popover in-place — the arrow stays pinned to the original
// positioningRect. ❌ NEVER call popover.show() again on resize.

// MARK: - AppDelegate + NSApplicationDelegate (termination)
//
// WHY plain `extension AppDelegate` (no conformance label):
// `AppDelegate` is declared `NSApplicationDelegate` on the class itself in
// AppDelegate.swift. Swift treats a protocol conformance as belonging to
// the type, not to a specific extension — methods in any extension of that
// type satisfy the conformance. Re-writing `extension AppDelegate: NSApplicationDelegate`
// here is a compile error ("redundant conformance"). The plain extension form
// is correct; `applicationShouldTerminate` is still dispatched by AppKit as
// an NSApplicationDelegate callback.

extension AppDelegate {

    /// Cancels domain-level tasks before the app exits, then returns `.terminateNow`.
    ///
    /// Without this, AppKit's default `applicationShouldTerminate` behaviour
    /// stalls on the first `terminate(nil)` call while active structured tasks
    /// (polling loops, observation tasks) keep the run loop busy — causing the
    /// quit button and Cmd+Q to appear to require a double press (#2153).
    ///
    /// SCOPE: delegates to `appState.stop()` which cancels `statusIconTask`,
    /// `signOutTask`, and the `runnerStore` poll loop. SwiftUI `@State`-owned
    /// tasks (`sheetPoll` in `PanelContainerView`, `displayTick` in
    /// `PanelMainView`) are NOT cancelled here — they are implicitly terminated
    /// by the process exit and require no explicit cancellation.
    ///
    /// Fires for ALL quit paths: in-app button, Cmd+Q, Dock, system shutdown.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("AppDelegate › applicationShouldTerminate — stopping appState tasks")
        appState.stop()
        return .terminateNow
    }
}

// MARK: - AppDelegate + NSPopoverDelegate

/// NSPopoverDelegate conformance: owns popover construction, KVO, and open/close callbacks.
extension AppDelegate: NSPopoverDelegate {

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO and async subscriptions.
    ///
    /// Called exactly once from `applicationDidFinishLaunching`. See the file-level comment block
    /// for full rationale on popover behavior, sheet handling, and sizing.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        // .applicationDefined: popoverShouldClose(_:) is consulted on every
        // outside interaction. Re-asserting before every show() ensures AppKit
        // does not revert to .transient between sessions.
        // Manual NSEvent monitor + NSWorkspace observer handle hide-on-app-switch.
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — popover created, wiring KVO + subscriptions")

        setupKVO(controller: controller)
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

    // MARK: KVO

    /// Observes `preferredContentSize` and updates both width and height.
    private func setupKVO(controller: NSHostingController<AnyView>) {
        log("AppDelegate › setupKVO — attaching preferredContentSize observer")
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            // KVO can fire on a background thread — hop to main before touching UI.
            Task { @MainActor [weak self] in self?.resizeAndRepositionPanel() }
        }
    }
}
