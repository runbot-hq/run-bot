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
// SIZE / SIDE-JUMP FIX (fix/#2237):
// popover.contentSize is updated via two paths:
//   1. AppKit-internal: sizingOptions = .preferredContentSize causes AppKit
//      to write contentSize directly when SwiftUI preferredContentSize changes
//      (row expand, view swap, etc.).
//   2. Manual KVO: setupKVO() observes preferredContentSize and calls
//      resizeAndRepositionPanel(), which also writes contentSize.
//
// Both paths now flow through GuardedPopover.contentSize setter (below),
// which applies the isMenuBarHidden guard (buttonY >= screenH) before
// forwarding to super. This intercepts ALL writes regardless of call path.
//
// ✅ Keep sizingOptions = .preferredContentSize — it is required to keep
//    NSHostingController computing and publishing preferredContentSize.
//    Without it the KVO observer never fires and the popover freezes.
// ✅ Keep the KVO observer in setupKVO() — it handles clamping (min/max)
//    and the resizeAndRepositionPanel() logging path.
// ❌ NEVER call popover.show() again on resize.

// MARK: - GuardedPopover

/// NSPopover subclass that intercepts all `contentSize` writes and skips them
/// when the auto-hide menubar is hidden (buttonY >= screenH).
///
/// ## Why this is needed
/// `sizingOptions = .preferredContentSize` causes AppKit to write `contentSize`
/// internally whenever SwiftUI's `preferredContentSize` changes (row expand,
/// view swap, etc.). This write path bypasses any guard in
/// `resizeAndRepositionPanel()` — it fires synchronously inside the SwiftUI
/// layout pass, before our KVO Task is scheduled.
///
/// By owning the setter we intercept both the AppKit-internal write AND the
/// manual write from `resizeAndRepositionPanel()` in a single place.
///
/// ## Guard logic
/// When the auto-hide menubar is hidden the Dock pushes the NSStatusItem
/// button window off the top of the screen: `buttonWin.frame.origin.y >=
/// screen.frame.height`. Any `contentSize` write in this state causes AppKit
/// to re-run anchor geometry against the off-screen button, collapsing the
/// popover x-origin to 0 (side-jump). We skip the write; the current size is
/// already correct. The next write after the menubar re-appears has a valid
/// button position and goes through normally.
///
/// ## What does NOT work as a signal
/// `button.window.screen == nil` — screen association is retained even when
/// the menubar is hidden. The correct signal is `buttonY >= screenH`.
final class GuardedPopover: NSPopover {

    /// Weak reference to the status item, used to read button window geometry
    /// for the isMenuBarHidden guard. Set by AppDelegate after setup.
    weak var statusItem: NSStatusItem?

    override var contentSize: NSSize {
        get { super.contentSize }
        set {
            let buttonWin = statusItem?.button?.window
            let buttonWinFrame = buttonWin?.frame
            let buttonScreen = buttonWin?.screen
            let buttonY = buttonWinFrame?.origin.y ?? -1
            let screenH = buttonScreen?.frame.height ?? -1
            let isMenuBarHidden = buttonScreen != nil && buttonY >= screenH
            log("GuardedPopover › contentSize setter — "
                + "new=(\(newValue.width),\(newValue.height)) "
                + "current=(\(super.contentSize.width),\(super.contentSize.height)) "
                + "buttonY=\(buttonY) screenH=\(screenH) "
                + "isMenuBarHidden=\(isMenuBarHidden)")
            guard !isMenuBarHidden else {
                log("GuardedPopover › contentSize setter — SKIP: "
                    + "isMenuBarHidden=true (buttonY=\(buttonY) >= screenH=\(screenH)) (fix/#2237)")
                return
            }
            log("GuardedPopover › contentSize setter — WRITE (\(newValue.width),\(newValue.height))")
            super.contentSize = newValue
        }
    }
}

// MARK: - AppDelegate + NSPopoverDelegate

/// Extension responsible for NSPopover construction, KVO, and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the SwiftUI hosting controller, wires KVO
    /// and async subscriptions.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        // sizingOptions = .preferredContentSize is required to keep
        // NSHostingController computing and publishing preferredContentSize.
        // Without it, preferredContentSize never changes and the KVO observer
        // never fires — the popover freezes at initial size.
        // The side-jump from AppKit's internal contentSize writes is intercepted
        // by GuardedPopover.contentSize setter instead. See SIZE note in file header.
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = GuardedPopover()
        newPopover.statusItem = statusItem   // wire geometry source for guard
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        // .applicationDefined: popoverShouldClose(_:) is consulted on every
        // dismiss attempt. Returns true, keeping the popover alive only when
        // the manual monitor's hasActiveSheet guard fires.
        // Manual NSEvent monitor + NSWorkspace observer handle hide-on-app-switch.
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — GuardedPopover created, wiring KVO + subscriptions")

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

    /// Observes `preferredContentSize` and routes every resize through
    /// `resizeAndRepositionPanel()` for clamping (min/max width/height).
    ///
    /// The actual side-jump guard now lives in `GuardedPopover.contentSize`
    /// and fires for both this path and AppKit's internal sizingOptions path.
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
