// AppDelegate.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// Owns: NSStatusItem, NSPopover, NSHostingController, event monitor,
// workspace observer, and file picker presentation.
//
// DISMISS STRATEGY:
//   - .behavior = .applicationDefined (AppKit never auto-closes)
//   - Global NSEvent monitor fires on outside click → performClose()
//   - NSWorkspace.didActivateApplicationNotification closes on app-switch;
//     self-activation (e.g. after NSOpenPanel closes) is ignored
//   - popoverShouldClose returns false when overlayCount > 0, blocking
//     dismissal while a sheet or file picker is open
//
// ACTIVE APPEARANCE:
//   NSApp.activate(ignoringOtherApps: true) on every openPopover() so
//   AppKit renders all controls in their active (non-greyed) state.

import AppKit
import SwiftUI

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var eventMonitor: Any?
    private var workspaceObserver: (any NSObjectProtocol)?
    private let appState = NavSheetAppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate", "applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Flask"
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.target = self
        log("StatusItem", "set up")
    }

    @objc private func togglePopover() {
        popover.isShown ? closePopover() : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        button.isHighlighted = true
        log("Popover", "shown")
        startEventMonitor()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        let root = NavSheetRootView()
            .environment(appState)
        hostingController = NSHostingController(rootView: AnyView(root))
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.animates = true
        popover.behavior = .applicationDefined
        popover.delegate = self
        log("Popover", "configured")
    }

    // MARK: - Workspace observer (close on app-switch)

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.popover.isShown else { return }
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            guard activated != NSRunningApplication.current else {
                log("WorkspaceObserver", "self-activation, ignoring")
                return
            }
            log("WorkspaceObserver", "other app activated (\(activated?.localizedName ?? "?")) -> close")
            self.popover.performClose(nil)
        }
        log("WorkspaceObserver", "installed")
    }

    // MARK: - Event monitor (outside click)

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.popover.performClose(nil)
        }
        log("EventMonitor", "started")
    }

    private func stopEventMonitor() {
        guard let m = eventMonitor else { return }
        NSEvent.removeMonitor(m)
        eventMonitor = nil
        log("EventMonitor", "stopped")
    }

    // MARK: - Window helpers

    var popoverWindow: NSWindow? {
        popover.contentViewController?.view.window
    }

    var sheetWindow: NSWindow? {
        popoverWindow?.childWindows?.first(where: { $0.isVisible })
    }
}

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let allow = appState.overlayCount == 0
        log("Popover", "popoverShouldClose -> \(allow) (overlayCount=\(appState.overlayCount))")
        return allow
    }
    func popoverDidClose(_ notification: Notification) {
        log("Popover", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
    }
}
