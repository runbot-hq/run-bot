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
// Each content view is wrapped with background(GeometryReader) by
// wrapWithSizeReporter(_:) BEFORE being type-erased to AnyView.
// The GeometryReader lives INSIDE the AnyView boundary so it fires on
// every layout pass — including async @Observable state changes — not
// just on navigate() calls.
// sizingOptions = [] opts out of AppKit's .intrinsicContentSize default
// (macOS 14+) which would compete with the GeometryReader path.
//
// ❌ NEVER call popover.show() again on resize.
// ❌ NEVER replace hostingController.rootView after setup.
// ❌ NEVER add a GeometryReader to NavigationShellView — it sits outside
//    the AnyView boundary and misses async state-driven size changes.

/// Extension responsible for NSPopover construction and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Builds the NSPopover, embeds the permanent NavigationShellView root,
    /// wires async subscriptions.
    ///
    /// The initial content view is wrapped with `wrapWithSizeReporter(_:)` so
    /// its GeometryReader is inside the AnyView boundary from the first frame —
    /// matching the same wrapping applied by `navigate(to:)` for all subsequent
    /// content changes.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")

        // Wrap initial content with size reporter before storing in the shell.
        // This matches navigate(to:)'s wrapping so the GeometryReader is always
        // inside the AnyView boundary from the very first layout pass.
        let shell = NavigationShell(initial: wrapWithSizeReporter(mainView()))
        navigationShell = shell

        // NavigationShellView is the permanent NSHostingController root.
        // It is a pure content-slot view — no GeometryReader, no onSizeChange.
        // Sizing is owned by the GeometryReader baked into each content value.
        let shellView = NavigationShellView()
        let rootView = wrapEnv(shellView)
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
