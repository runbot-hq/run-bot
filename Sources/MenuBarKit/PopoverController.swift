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
//   - Install the NSWorkspace app-switch observer
//   - Implement popoverShouldClose via the MBKOverlayGate
//   - Reset the overlay gate in popoverDidClose (safety net)
//
// USAGE:
//   1. Create a MBKPopoverController with your root SwiftUI view and an
//      MBKOverlayGate instance.
//   2. Call `setup()` from applicationDidFinishLaunching.
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

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    /// Overlay gate — read in popoverShouldClose and reset in popoverDidClose.
    private let overlayGate: MBKOverlayGate

    /// The root SwiftUI view hosted inside the popover.
    private let rootView: AnyView

    /// SF Symbol name for the status-bar icon.
    private let symbolName: String

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!

    // nonisolated(unsafe): The NSEvent monitor API returns an opaque Any? token
    // that must be stored for later removal. The token itself has no actor
    // requirement — only our read/write of this property is actor-sensitive,
    // and every access is gated behind @MainActor methods (startEventMonitor /
    // stopEventMonitor). nonisolated(unsafe) is the correct Swift 6 annotation
    // for a stored property that is manually guaranteed to be safe.
    nonisolated(unsafe) private var eventMonitor: Any?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle"
    ) {
        self.rootView = AnyView(rootView)
        self.overlayGate = overlayGate
        self.symbolName = symbolName
    }

    // MARK: - Setup

    /// Call from applicationDidFinishLaunching.
    public func setup() {
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
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        button.isHighlighted = true
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
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.animates = true
        // .applicationDefined = we handle all dismiss logic ourselves.
        // This disables AppKit's built-in auto-dismiss entirely — nothing
        // closes the popover unless we call performClose() ourselves.
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        // queue: nil delivers on the poster's thread (not necessarily main).
        // Task { @MainActor } is the Swift 6-correct hop — see file header.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            // Capture before the actor hop — NSRunningApplication is Sendable.
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            Task { @MainActor [weak self] in
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

    private func stopEventMonitor() {
        guard let m = eventMonitor else { return }
        NSEvent.removeMonitor(m)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
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
