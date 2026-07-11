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
//   - Implement popoverShouldClose via the injected hasActiveOverlay closure
//   - Reset the overlay gate in popoverDidClose (safety net)
//
// USAGE:
//   1. Create a PopoverController with your root SwiftUI view.
//   2. Inject a `hasActiveOverlay` closure that returns true while any sheet
//      or file picker is open on top of the popover.
//   3. Call `setup()` from applicationDidFinishLaunching.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads `hasActiveOverlay()`. The caller is responsible
//   for returning true from that closure whenever any overlay (SwiftUI sheet,
//   NSOpenPanel) is live. MBKAnchoredSheet and MBKFilePicker manage this
//   automatically via the MBKOverlayGate they receive at init.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes. Never leaks a
//   persistent global listener.
//
// WORKSPACE OBSERVER:
//   Installed once at setup(). Closes the popover whenever another app
//   becomes active. Self-activations (NSApp.activate) are ignored.

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject {

    // MARK: - Configuration

    /// Returns true while any overlay (sheet, file picker) is live.
    /// Set by the caller at init; read by popoverShouldClose.
    private let hasActiveOverlay: () -> Bool

    /// The root SwiftUI view hosted inside the popover.
    private let rootView: AnyView

    /// SF Symbol name for the status-bar icon.
    private let symbolName: String

    // MARK: - Owned objects

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!

    // nonisolated(unsafe): NSEvent monitor token must be stored but is only
    // ever touched on MainActor.
    nonisolated(unsafe) private var eventMonitor: Any?

    // MARK: - Init

    public init<Content: View>(
        rootView: Content,
        symbolName: String = "menubar.rectangle",
        hasActiveOverlay: @escaping () -> Bool
    ) {
        self.rootView = AnyView(rootView)
        self.symbolName = symbolName
        self.hasActiveOverlay = hasActiveOverlay
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
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    // MARK: - Workspace observer

    private func setupWorkspaceObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
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
        let block = hasActiveOverlay()
        mbkLog("PopoverController", "popoverShouldClose blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        mbkLog("PopoverController", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        // Safety net: the gate is normally cleared by MBKAnchoredSheet /
        // MBKFilePicker, but if the popover closes via any other path the flag
        // would be left true, permanently blocking future dismissals.
        // Cleared here as ground truth that no overlay can still be live.
        _overlayGateSafetyReset?()
        mbkLog("PopoverController", "overlay gate reset on close")
    }

    // Called by MBKOverlayGate to register the safety-reset closure.
    // Internal — not public API.
    var _overlayGateSafetyReset: (() -> Void)? {
        get { __overlayGateSafetyReset }
        set { __overlayGateSafetyReset = newValue }
    }
    private var __overlayGateSafetyReset: (() -> Void)?
}
