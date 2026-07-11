// AppDelegate.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// DISMISS STRATEGY:
//   - .behavior = .applicationDefined (AppKit never auto-closes)
//   - Global NSEvent monitor fires on outside click → performClose()
//   - NSWorkspace.didActivateApplicationNotification closes on app-switch
//   - popoverShouldClose checks the window hierarchy directly:
//       win.sheets non-empty  → NSOpenPanel is attached, block dismiss
//       win.childWindows non-empty → SwiftUI sheet is attached, block dismiss

import AppKit
import SwiftUI

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    nonisolated(unsafe) private var eventMonitor: Any?
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
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "flask.fill", accessibilityDescription: "Spike")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
        log("StatusItem", "set up")
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : openPopover()
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        button.isHighlighted = true
        log("Popover", "shown")
        startEventMonitor()
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        hostingController = NSHostingController(rootView: AnyView(NavSheetRootView().environment(appState)))
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    log("WorkspaceObserver", "self-activation, ignoring")
                    return
                }
                log("WorkspaceObserver", "other app (\(activated?.localizedName ?? "?")) -> close")
                self.popover.performClose(nil)
            }
        }
        log("WorkspaceObserver", "installed")
    }

    // MARK: - Event monitor (outside click)

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }
        log("EventMonitor", "started")
    }

    private func stopEventMonitor() {
        guard let m = eventMonitor else { return }
        NSEvent.removeMonitor(m)
        eventMonitor = nil
        log("EventMonitor", "stopped")
    }
}

extension NavSheetAppDelegate: NSPopoverDelegate {
    func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard let win = popover.contentViewController?.view.window else { return true }
        let hasOverlay = !win.sheets.isEmpty
            || !(win.childWindows?.filter { $0.isVisible } ?? []).isEmpty
        log("Popover", "popoverShouldClose hasOverlay=\(hasOverlay)")
        return !hasOverlay
    }
    func popoverDidClose(_ notification: Notification) {
        log("Popover", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
    }
}
