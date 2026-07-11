// AppDelegate.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// POPOVER DISMISS STRATEGY:
//
//   The goal is: dismiss on outside-click and on app-switch, but NOT when the
//   user is interacting with a sheet or file picker that is layered on top.
//
//   Three mechanisms work together:
//
//   1. popover.behavior = .applicationDefined
//      Disables AppKit's built-in auto-dismiss entirely. Nothing closes the
//      popover unless we call performClose() ourselves. This gives us full
//      control but means we are responsible for all close triggers.
//
//   2. Global NSEvent monitor (outside-click)
//      Listens for left/right mouse-down events outside the app. When one fires
//      we call performClose(), which goes through popoverShouldClose first.
//      The monitor is started when the popover opens and stopped when it closes
//      to avoid leaking a persistent global listener.
//
//   3. NSWorkspace.didActivateApplicationNotification (app-switch)
//      Fires whenever any app becomes active. If it isn't us, close.
//      Self-activations (e.g. when we call NSApp.activate) are ignored.
//
// popoverShouldClose — the dismiss gate:
//
//   Even when performClose() is called by the two mechanisms above, we may want
//   to block it if an overlay is open on top of the popover:
//
//   - win.sheets non-empty → NSOpenPanel is attached as a sheet to the popover
//     window (this is what NSOpenPanel.beginSheetModal does). Closing the popover
//     now would tear it down underneath the user.
//
//   - win.childWindows non-empty → The SwiftUI sheet has been anchored as a child
//     window (see AnchoredSheet.swift). Same reason — block dismiss.
//
//   Both checks read live window state, so they cannot desync the way a counter would.

import AppKit
import SwiftUI

@MainActor
final class NavSheetAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    // nonisolated(unsafe) because NSEvent.addGlobalMonitorForEvents returns an
    // opaque Any token that must be stored but is only ever touched on MainActor.
    nonisolated(unsafe) private var eventMonitor: Any?
    private let appState = NavSheetAppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("AppDelegate", "applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)  // hide from Dock and app-switcher
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "flask.fill", accessibilityDescription: "Spike")
            button.image?.isTemplate = true  // lets macOS tint it for dark/light mode
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
        // activate so the popover becomes key and receives keyboard events
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
        // sizingOptions = .preferredContentSize lets SwiftUI drive the popover
        // size automatically as views change — no manual contentSize bookkeeping.
        hostingController.sizingOptions = .preferredContentSize
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.animates = true
        // .applicationDefined = we handle all dismiss logic ourselves (see header)
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
                    // NSApp.activate() above triggers this notification for ourselves;
                    // ignore it or we'd immediately close the popover we just opened.
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
                // Goes through popoverShouldClose — will be blocked if a sheet
                // or file picker is open.
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
        // win.sheets: NSOpenPanel (or any sheet) attached via beginSheetModal
        // win.childWindows filtered to visible: SwiftUI sheet anchored via addChildWindow
        let hasOverlay = !win.sheets.isEmpty
            || !(win.childWindows?.filter { $0.isVisible } ?? []).isEmpty
        log("Popover", "popoverShouldClose hasOverlay=\(hasOverlay)")
        return !hasOverlay  // true = allow close, false = block
    }

    func popoverDidClose(_ notification: Notification) {
        log("Popover", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
    }
}
