// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction and subscriptions that drive icon/store updates.
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
// OUTSIDE-CLICK / APP-SWITCH HIDE (#1195 — what actually works):
// Both are handled by a manual NSEvent global monitor (outsideClickMonitor)
// and an NSWorkspace observer (workspaceObserver), both installed by openPanel()
// and torn down by tearDownOpenState().
//
// SHEET HANDLING:
// SwiftUI .sheet() attaches as a child NSWindow to the popover's backing
// window. PanelContainerView polls NSWindow.sheets and overlays
// Color.black.opacity(0.35) when a sheet is present.
//
// SIZE NOTE (matches runbot-hq/MenuBarKit PR #6 exactly):
// popover.contentSize is driven by NavigationShellView's background
// GeometryReader — SwiftUI reporting its OWN size, not KVO. The shell is
// the permanent NSHostingController root; its GeometryReader is never
// replaced by navigate() calls. See NavigationShell.swift for the full
// architecture and the NavigationShell.swift SIZE REPORTING note.
//
// sizingOptions = [] is set explicitly (matches PR #6). This opts out of
// AppKit's .intrinsicContentSize default (macOS 14+), which would drive
// popover.contentSize from preferredContentSize independently — a competing
// path that can override the GeometryReader writes and freeze the popover.
//
// ❌ NEVER call popover.show() again on resize.
// ❌ NEVER replace hostingController.rootView after setup.

/// Extension responsible for NSPopover construction and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the permanent NavigationShellView root,
    /// wires async subscriptions. Size is driven by NavigationShellView's
    /// GeometryReader — see SIZE NOTE above.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        // Build the initial content (main view) and the permanent shell.
        let shell = NavigationShell(initial: mainView())
        navigationShell = shell

        // NavigationShellView is the permanent NSHostingController root.
        // It wraps shell.content in background(GeometryReader{...}) so the
        // GeometryReader always exists at the root level regardless of what
        // navigate() puts into the content slot.
        //
        // wrapEnv is called here so the shell view has the full environment
        // (panelVisibilityState, appState, overlayGate, suppressHidePanel).
        // NavigationShell itself is also injected so NavigationShellView can
        // read the content slot via @Environment.
        let shellView = NavigationShellView(
            onSizeChange: { [weak self] size in
                self?.resizeAndRepositionPanel(preferredSize: size)
            }
        )
        let rootView = wrapEnv(shellView)
            // Inject NavigationShell so NavigationShellView can read content.
            // Must be OUTSIDE wrapEnv so it is available to NavigationShellView
            // before any child views that wrapEnv might itself inject.
            // AnyView type-erases, so re-wrap with the shell environment.
        let finalRoot = AnyView(rootView.environment(shell))

        let controller = NSHostingController(rootView: finalRoot)
        // sizingOptions = [] — matches runbot-hq/MenuBarKit PR #6 explicitly.
        // Opts out of AppKit's default (.intrinsicContentSize on macOS 14+)
        // which would drive popover.contentSize from preferredContentSize
        // independently, competing with the GeometryReader path.
        controller.sizingOptions = []
        hostingController = controller

        let newPopover = NSPopover()
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — popover created, NavigationShell wired")
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        #if DEBUG
        log("AppDelegate › popoverShouldClose — CALLED behavior=\(popover.behavior.rawValue) panelIsOpen=\(panelIsOpen) caller=\(Thread.callStackSymbols[1])")
        #endif
        log("AppDelegate › popoverShouldClose — returning true (allowing close)")
        return true
    }

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
}
