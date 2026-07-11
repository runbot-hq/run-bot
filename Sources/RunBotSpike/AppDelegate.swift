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
//   to block it if an overlay is open on top of the popover. The gate reads
//   appState.hasActiveOverlay, which is set/cleared by:
//     - anchoredSheet modifier (SwiftUI sheets)
//     - openFilePicker (NSOpenPanel)
//
//   WHY NOT win.sheets / win.childWindows:
//     Earlier versions walked the window hierarchy in popoverShouldClose.
//     This was fragile — timing of addChildWindow and OS version differences
//     meant the hierarchy didn't always reflect SwiftUI state accurately.
//     appState.hasActiveOverlay is set synchronously when isPresented flips,
//     so it can never lag behind the actual UI state.
//
// WHY hasActiveOverlay IS CLEARED IN popoverDidClose:
//   anchoredSheet and openFilePicker clear hasActiveOverlay on normal dismiss.
//   But if the popover is closed by a path that bypasses those flows (system
//   gesture, future code path, crash recovery), the flag could be left true.
//   A stale true means popoverShouldClose blocks every subsequent dismiss
//   permanently until the app restarts. Clearing it unconditionally in
//   popoverDidClose is the safety net — the popover closing is ground truth
//   that no overlay can still be live.
//
// DIVERGENCE FROM PopoverLifecycleCoordinator:
//   The production PopoverLifecycleCoordinator uses isSheetDismissing +
//   suppressHidePanel() to suppress the workspace observer during sheet teardown.
//   This spike does NOT use that flag — hasActiveOverlay is cleared by the
//   anchoredSheet modifier on dismiss, which is synchronous with SwiftUI state.
//   Do not conflate the two approaches when migrating; the production flag exists
//   to handle a teardown race that this cleaner architecture avoids entirely.

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
            queue: nil  // nil = deliver on the poster's thread; we hop to MainActor below
        ) { [weak self] notification in
            // Capture activated before the actor hop — NSRunningApplication is
            // Sendable so this crosses the isolation boundary safely.
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication
            // Task { @MainActor } is the Swift 6-correct hop: compiler-enforced
            // actor isolation (P4). Previously used MainActor.assumeIsolated with
            // queue: .main — that is a runtime assertion, not a compile-time
            // guarantee, and violates P4. queue: nil + Task { @MainActor } gives
            // the same delivery ordering with full actor-checking.
            Task { @MainActor [weak self] in
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
        // Task { @MainActor } rather than DispatchQueue.main.async — the global
        // monitor callback is a non-isolated closure; Task { @MainActor } is the
        // Swift 6-correct way to hop to the main actor (P4). DispatchQueue.main.async
        // bypasses actor checking and should not be copied into the main app.
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Goes through popoverShouldClose — will be blocked if
                // hasActiveOverlay is true.
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
        // Single authoritative gate: set by anchoredSheet modifier and
        // openFilePicker. No window hierarchy walk needed.
        let block = appState.hasActiveOverlay
        log("Popover", "popoverShouldClose blocked=\(block)")
        return !block
    }

    func popoverDidClose(_ notification: Notification) {
        log("Popover", "popoverDidClose")
        setButtonHighlight(false)
        stopEventMonitor()
        // Safety net: clear the dismiss gate unconditionally. Under normal flow
        // anchoredSheet and openFilePicker clear hasActiveOverlay themselves, but
        // if the popover is closed by any path that bypasses those flows the flag
        // would be left true, permanently blocking all future dismiss attempts.
        // The popover closing is ground truth that no overlay can still be live.
        appState.hasActiveOverlay = false
        log("Popover", "hasActiveOverlay reset to false on close")
    }
}
