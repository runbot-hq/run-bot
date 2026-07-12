// PopoverController.swift
// RunBot
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// RESPONSIBILITIES:
//   - Create and show/hide the NSPopover
//   - Manage the NSStatusItem button highlight
//   - Install/remove the outside-click NSEvent monitor
//   - Install/remove the NSWorkspace app-switch observer
//   - Implement popoverShouldClose via the MBKOverlayGate
//   - Reset the overlay gate in popoverDidClose (safety net)
//
// USAGE:
//   1. Create a MBKPopoverController with your root SwiftUI view and an
//      MBKOverlayGate instance.
//   2. Call `setup()` from applicationDidFinishLaunching — see setup() doc
//      comment for the strict ordering requirement.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads overlayGate.hasActiveOverlay. MBKAnchoredSheet
//   and mbkOpenFilePicker manage the gate automatically — the host app never
//   needs to touch it directly.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes. Never leaks a
//   persistent global listener.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor } (not queue: .main):
//   The production PopoverLifecycleCoordinator uses queue: .main +
//   MainActor.assumeIsolated. That pattern is a runtime assertion, not a
//   compile-time guarantee, and violates Swift 6's actor-isolation rules (P4).
//   queue: nil delivers on the poster's thread; Task { @MainActor } is then
//   the Swift 6-correct hop to the main actor — compiler-enforced, not
//   asserted. The asymmetry with the production coordinator is intentional
//   and correct. The production coordinator should be updated to match.
//
// WORKSPACE OBSERVER — performClose on already-closed popover:
//   If the workspace observer Task is still enqueued when popoverDidClose fires
//   (e.g. user Command-Tabs and popoverDidClose has already run by the time the
//   Task hops to MainActor), performClose(nil) is called on a closed popover.
//   NSPopover.performClose on a closed popover is documented as a no-op, so
//   this is safe. The guard self.popover.isShown at the top of the Task body
//   makes the intent explicit — it is not defensive cargo-culting.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   These three properties use ! (IUO) because they are assigned in setup(),
//   not in init(). This is the standard setup()-pattern for AppKit types that
//   require a post-init configuration step. They are safe because setup() must
//   be called from applicationDidFinishLaunching before any user interaction
//   is possible — the app's own main thread cannot reach togglePopover() before
//   that point.
//
//   If you are writing a unit test that calls togglePopover() without first
//   calling setup(), it WILL crash on the ! unwrap. Call setup() first, or
//   restructure to init-time wiring before extracting this into a fully
//   testable library.
//
//   ❌ Do NOT replace these with optionals without also replacing setup() with
//   an init parameter — partial initialisation with optionals silently turns
//   programming errors into runtime nil returns that are harder to diagnose
//   than a clean crash.
//
// nonisolated(unsafe) — WHY eventMonitor AND workspaceObserver USE IT:
//   Both properties hold opaque tokens returned by AppKit APIs:
//     - eventMonitor: Any? from NSEvent.addGlobalMonitorForEvents
//     - workspaceObserver: NSObjectProtocol? from NSNotificationCenter.addObserver
//   Neither token type is Sendable, so the Swift 6 compiler rejects them as
//   @MainActor stored properties used in deinit (which is nonisolated per SE-0327).
//
//   nonisolated(unsafe) is the correct annotation because:
//     1. Every live read/write of both properties is @MainActor-isolated
//        (setupWorkspaceObserver, startEventMonitor, stopEventMonitor, deinit).
//     2. deinit runs only after the last strong reference drops. In normal app
//        lifetime, MBKPopoverController is created once in applicationDidFinishLaunching
//        and outlives all concurrent work — no concurrent access is possible.
//
//   LIMITATION: if MBKPopoverController is ever used with a SHORTER lifetime
//   (torn down and recreated, or held by a scoped owner), the singleton-lifetime
//   assumption no longer holds. In that case, replace the two tokens with a
//   proper teardown method that is guaranteed to be called on the main actor
//   before release, and remove nonisolated(unsafe).
//
//   ❌ Do NOT add @unchecked Sendable to these token types as a workaround —
//   that would suppress the warning without providing any actual safety.

import AppKit
import SwiftUI

/// Manages the full NSPopover and NSStatusItem lifecycle for a macOS menu-bar app.
/// Inject a root SwiftUI view and an MBKOverlayGate at init time, then call `setup()`
/// from `applicationDidFinishLaunching`.
@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    /// Overlay gate — read in popoverShouldClose and reset in popoverDidClose.
    private let overlayGate: MBKOverlayGate

    /// The root SwiftUI view hosted inside the popover.
    private let rootView: AnyView

    /// SF Symbol name for the status-bar icon.
    private let symbolName: String

    /// Initial popover content size. The hosting controller's
    /// preferredContentSize may override this at runtime as SwiftUI measures
    /// the root view, but this value anchors the first-show size.
    private let contentSize: NSSize

    // MARK: - Owned objects

    /// The status bar item that houses the menu-bar icon and acts as the popover anchor.
    private var statusItem: NSStatusItem!

    /// The managed NSPopover instance.
    private var popover: NSPopover!

    /// Hosting controller that wraps the root SwiftUI view inside the popover.
    private var hostingController: NSHostingController<AnyView>!

    /// Guards against double-call of setup(). See setup() for rationale.
    private var isSetUp = false

    // nonisolated(unsafe): see nonisolated(unsafe) section in the file header.
    // Short version: every live access is @MainActor-gated; deinit is safe
    // because this controller is expected to outlive all concurrent work
    // (singleton-lifetime assumption — see header for the limitation).
    /// Opaque token for the global NSEvent monitor; nil when no monitor is active.
    nonisolated(unsafe) private var eventMonitor: Any?

    // nonisolated(unsafe): same rationale as eventMonitor above — see file header.
    /// Opaque token for the NSWorkspace app-activation observer; nil until setup() runs.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

    /// Creates a controller with the given root view, overlay gate, and optional display options.
    /// - Parameters:
    ///   - rootView: The SwiftUI view tree to host inside the popover.
    ///   - overlayGate: Shared gate that blocks dismiss while a sheet or file picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    ///   - contentSize: Initial popover size. Defaults to 320 × 300 pt.
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        contentSize: NSSize = NSSize(width: 320, height: 300)
    ) {
        self.rootView = AnyView(rootView)
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.contentSize = contentSize
    }

    // MARK: - Setup

    /// Wires the status item, popover, and observers.
    ///
    /// **Must be called from `applicationDidFinishLaunching` before any user
    /// interaction is possible.** Assigns the three IUO properties (`statusItem`,
    /// `popover`, `hostingController`). Any call to `togglePopover()` before
    /// `setup()` completes will crash on the `!` unwrap — this is intentional;
    /// a crash surfaces the ordering error immediately rather than silently
    /// producing a nil-op. See IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    ///
    /// ❌ NEVER call `setup()` more than once. A `precondition` guards this at
    /// runtime. A second call would otherwise silently leak the old `NSStatusItem`
    /// and any installed observers without removing them.
    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once. See setup() doc comment.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Status item

    /// Configures the NSStatusItem and wires the toggle action to the button.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    /// Toggles the popover open or closed when the status-bar button is clicked.
    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Shows the popover relative to the status-bar button and starts the outside-click monitor.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        // NOTE: isHighlighted is NOT set here. popoverWillShow handles it via
        // the delegate so all show paths (including programmatic) are covered.
        // Setting it here too would be redundant and could diverge if a future
        // show path bypasses openPopover().
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    /// Sets the status-bar button highlight state.
    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// Creates and configures the NSPopover with applicationDefined behaviour so all
    /// dismiss logic is handled exclusively by this controller.
    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = true
        // .applicationDefined = we handle all dismiss logic ourselves.
        // This disables AppKit's built-in auto-dismiss entirely — nothing
        // closes the popover unless we call performClose() ourselves.
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    // MARK: - Workspace observer

    /// Installs the NSWorkspace app-activation observer that closes the popover
    /// when the user switches to another app. Stores the returned token in
    /// `workspaceObserver` so it can be removed in `deinit`.
    private func setupWorkspaceObserver() {
        // queue: nil delivers on the poster's thread (not necessarily main).
        // Task { @MainActor } is the Swift 6-correct hop — see file header.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Capture before the actor hop — NSRunningApplication is Sendable.
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                // isShown guard: if popoverDidClose already ran before this Task
                // hops to MainActor, performClose on a closed popover is a no-op
                // per NSPopover docs — but the guard makes the intent explicit.
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    // NSApp.activate() in openPopover() fires this for ourselves;
                    // ignore it or we'd immediately close the popover we just opened.
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Event monitor

    /// Installs a global NSEvent monitor for mouse-down events to detect outside clicks.
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        // The global monitor closure is non-isolated. Task { @MainActor } is
        // the Swift 6-correct hop (P4). DispatchQueue.main.async bypasses actor
        // checking and must not be used here.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Goes through popoverShouldClose — blocked if gate is armed.
                self?.popover.performClose(nil)
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    /// Removes the global NSEvent monitor and clears the token.
    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    // MARK: - Deallocation

    /// Removes the workspace observer on dealloc. In normal app lifetime
    /// `MBKPopoverController` is created once and never torn down, so this path
    /// is never taken — but storing and removing the token is correct regardless
    /// of lifetime, and makes the controller safe to use with a shorter-lived owner.
    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - NSPopoverDelegate

/// NSPopoverDelegate conformance — highlight, gate, and event monitor lifecycle.
extension MBKPopoverController: NSPopoverDelegate {
    // Single source of truth for the highlight — handles all show paths,
    // not just the openPopover() path.
    /// Highlights the status-bar button when the popover is about to appear.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }

    /// Returns false (blocking dismiss) while an overlay is active on the gate.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    /// Clears the button highlight, stops the event monitor, and resets the overlay gate.
    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        // Safety net: MBKAnchoredSheet and mbkOpenFilePicker clear the gate
        // on normal dismiss. This reset handles any path that bypasses those
        // flows (system gesture, future code path, crash recovery) — a stale
        // true would permanently block all future dismiss attempts until restart.
        // The popover closing is ground truth that no overlay can still be live.
        //
        // ORDER NOTE: stopEventMonitor() before gate reset is intentional and
        // safe. stopEventMonitor() is synchronous — the token is removed before
        // this line returns, so no queued outside-click Task can fire after this
        // point. Reversing the order would also be safe but buys nothing.
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
