// PopoverController.swift
// MenuBarKit
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
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off:
//   When a sheet (or file picker) is live, MBKPopoverController keeps the
//   popover open on app-switch and outside-click instead of hiding it.
//   popoverShouldClose returns false (via overlayGate.hasActiveOverlay), and
//   the workspace observer skips performClose while any overlay is active.
//
//   This is the simpler behaviour: the user's mental model is "sheet is
//   blocking, nothing else happens until I dismiss it." No hide-and-restore
//   cycle to reason about.
//
//   The alternative — hide the popover window without closing it so the sheet
//   NSWindow survives, then restore on reopen — is more AppKit-native but
//   significantly more complex. Some users may prefer it (popover disappears
//   on app-switch as they expect, even with a sheet open). If you want to
//   implement this, see `preservedSheetWindowHide`,
//   `hidePopoverWindowsPreservingSheets()`, and
//   `restorePopoverWindowsPreservingSheetsIfNeeded()` in RunBot's
//   `PopoverLifecycleCoordinator.swift` (git history) for a reference
//   implementation. That approach requires:
//     1. Hiding the NSPopover backing window (not performClose) when the
//        workspace observer fires and a sheet is active.
//     2. Tracking a `preservedSheetWindowHide` flag.
//     3. Restoring (un-hiding) the popover window on the next openPopover() call
//        when the flag is set, rather than calling popover.show().
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
//
// deinit TEARDOWN — thread-safety of NSWorkspace vs NSEvent removal:
//   deinit calls both NSWorkspace.shared.notificationCenter.removeObserver
//   and NSEvent.removeMonitor. NSEvent.removeMonitor is documented as
//   thread-safe. NSWorkspace.shared.notificationCenter.removeObserver is NOT
//   documented with the same guarantee.
//
//   This is safe here because of the singleton-lifetime assumption above:
//   MBKPopoverController is never released while concurrent work is in flight,
//   so deinit always runs after all @MainActor work has completed. If the
//   singleton assumption is ever violated, move both removals into an explicit
//   @MainActor teardown() method called before release.
//
//   This is an info-only note — not a current bug. Do not add a spurious
//   Task { @MainActor } wrapper around the deinit removals; that would be
//   a use-after-free (self is already deallocated when the Task runs).

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

    /// Initial popover content size.
    private let contentSize: NSSize

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!

    /// Guards against double-call of setup(). See setup() for rationale.
    private var isSetUp = false

    // nonisolated(unsafe): see nonisolated(unsafe) section in the file header.
    nonisolated(unsafe) private var eventMonitor: Any?
    // nonisolated(unsafe): same rationale as eventMonitor above — see file header.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Init

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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // ❌ DO NOT replace with NSApp.activate() (no-arg, the macOS 14+ form).
        // That call causes the popover window to flicker between active and
        // inactive chrome on every open — visually broken. Confirmed and
        // reverted in commit 7fe4caa. ignoringOtherApps: true must stay.
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = contentSize
        popover.animates = true
        // .applicationDefined = we handle all dismiss logic ourselves.
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        // queue: nil + Task { @MainActor } is the Swift 6-correct pattern — see file header.
        //
        // STAY-OPEN BEHAVIOUR: when a sheet or file picker is active, the guard
        // below skips performClose — the popover stays open on app-switch.
        // This is a deliberate trade-off. See STAY-OPEN-WHILE-SHEET-ACTIVE in
        // the file header if you want to implement the hide-and-restore alternative.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer — self-activation, ignoring")
                    return
                }
                // Keep popover open while any overlay (sheet / file picker) is active.
                // See STAY-OPEN-WHILE-SHEET-ACTIVE in the file header for the
                // trade-off rationale and the hide-and-restore alternative.
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer — overlay active, keeping popover open")
                    return
                }
                mbkLog("PopoverController", "workspace observer — other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Event monitor

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.popover.performClose(nil)
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    // MARK: - Deallocation

    // See deinit TEARDOWN in the file header for thread-safety rationale.
    // Do NOT wrap these removals in Task { @MainActor } — self is already
    // deallocated when a Task enqueued from deinit runs (use-after-free).
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

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        // Safety net — reset gate on close regardless of how we got here.
        overlayGate.hasActiveOverlay = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
