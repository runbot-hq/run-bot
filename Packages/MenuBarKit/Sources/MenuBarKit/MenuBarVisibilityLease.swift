// MenuBarVisibilityLease.swift
// MenuBarKit
//
// DIAGNOSTIC BUILD — read-only investigation of menu-bar retraction.
//
// All presentation-option writes, setMenuBarVisible calls, KVO observers,
// deferred Tasks, and the false→true toggle have been removed.
//
// This file now contains only:
//   - logMenuBarState(_:) — captures full system state on every tracked event
//   - A mouse-region transition monitor (logs only on region change, not per-move)
//   - acquire() / release() — lifecycle hooks that start/stop the mouse monitor
//     and log entry/exit state; no visibility writes
//
// Goal: identify the exact event immediately before menuBarVisible changes
// from true to false without interference from any RunBot-side state writes.

import AppKit

/// Diagnostic-only menu-bar state observer for `MBKPanelController`.
///
/// Acquire on panel open, release on panel close.
/// No presentation-option or visibility mutations are made.
@MainActor
final class MBKMenuBarVisibilityLease {

    // MARK: - State

    private var isAcquired = false
    private var mouseMonitor: Any?

    /// Tracks which region the pointer was last seen in, to log only transitions.
    private var lastPointerRegion: PointerRegion = .outside

    private enum PointerRegion: Equatable {
        case inPanel, inButtonWindow, outside
    }

    // MARK: - Public interface

    /// Whether this lease is currently active.
    var isActive: Bool { isAcquired }

    /// Returns presentation options with menu-bar hiding removed.
    /// Kept `nonisolated` so unit tests can call it without a live app.
    nonisolated static func pinnedOptions(
        from options: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var result = options
        result.remove(.autoHideMenuBar)
        result.remove(.hideMenuBar)
        return result
    }

    // MARK: - Acquire / release

    func acquire() {
        guard !isAcquired else {
            mbkLog("MenuBarVisibilityLease", "acquire -- already active")
            return
        }
        isAcquired = true
        startMouseMonitor()
        logMenuBarState("acquire")
    }

    func release() {
        guard isAcquired else {
            mbkLog("MenuBarVisibilityLease", "release -- inactive")
            return
        }
        logMenuBarState("release")
        stopMouseMonitor()
        isAcquired = false
        lastPointerRegion = .outside
    }

    // MARK: - Core diagnostic logger

    /// Logs the complete menu-bar-relevant system state for a named event.
    /// Call this whenever a tracked state change occurs.
    func logMenuBarState(_ event: String) {
        let pointer = NSEvent.mouseLocation
        let panelFrame = panelRef?.frame ?? .zero
        let buttonWindow = buttonWindowRef
        let buttonFrame = buttonWindow?.frame ?? .zero

        mbkLog(
            "MenuBarDiagnostics",
            """
            event=\(event) \
            appActive=\(NSApp.isActive) \
            panelVisible=\(panelRef?.isVisible ?? false) \
            panelKey=\(panelRef?.isKeyWindow ?? false) \
            pointer=(\(Int(pointer.x)),\(Int(pointer.y))) \
            pointerInPanel=\(panelFrame.contains(pointer)) \
            pointerInButtonWindow=\(buttonFrame.contains(pointer)) \
            menuBarVisible=\(NSMenu.menuBarVisible()) \
            requestedOptions=\(NSApp.presentationOptions.rawValue) \
            effectiveOptions=\(NSApp.currentSystemPresentationOptions.rawValue) \
            buttonWindowFrame=\(buttonFrame) \
            buttonHighlighted=\(buttonRef?.isHighlighted ?? false)
            """
        )
    }

    // MARK: - Weak refs injected by controller

    /// Set by MBKPanelController immediately after setup so the logger can
    /// read panel/button state without a strong retain cycle.
    weak var panelRef: NSPanel?
    weak var buttonWindowRef: NSWindow?
    weak var buttonRef: NSButton?

    // MARK: - Mouse region transition monitor

    private func startMouseMonitor() {
        stopMouseMonitor()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .mouseMoved
        ) { [weak self] _ in
            guard let self, self.isAcquired else { return }
            Task { @MainActor [weak self] in
                self?.checkPointerRegionTransition()
            }
        }
    }

    private func stopMouseMonitor() {
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMonitor = nil
        }
    }

    private func checkPointerRegionTransition() {
        let pointer = NSEvent.mouseLocation
        let panelFrame = panelRef?.frame ?? .zero
        let buttonFrame = buttonWindowRef?.frame ?? .zero

        let region: PointerRegion
        if panelFrame.contains(pointer) {
            region = .inPanel
        } else if buttonFrame.contains(pointer) {
            region = .inButtonWindow
        } else {
            region = .outside
        }

        guard region != lastPointerRegion else { return }
        lastPointerRegion = region
        logMenuBarState("pointer-region-\(region)")
    }
}
