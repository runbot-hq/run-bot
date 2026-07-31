// PanelController+Observers.swift
// MenuBarKit
//
// Workspace app-switch observer, screen-parameter observer, and outside-click
// monitor for MBKPanelController.
//
// Escape is handled by MBKPanel.cancelOperation(_:), not by a monitor — the
// panel takes key status, so Escape reaches the responder chain normally.
// See PanelController.swift file header for full design notes.
//
// The actual observer/monitor logic lives in PanelObservers.swift (non-generic
// @MainActor class) to avoid the spurious [#SendableMetatypes] warning that
// fires when Task { @MainActor [weak self] } captures a generic self.
// This file is a thin conformance + bridge only.

import AppKit

// MARK: - MBKPanelObserverTarget conformance

/// Observers and event monitors for `MBKPanelController`.
extension MBKPanelController: MBKPanelObserverTarget {}

// MARK: - Observer lifecycle bridge

/// Observers and event monitors for `MBKPanelController`.
extension MBKPanelController {

    // MARK: - Workspace observer

    /// Registers for `NSWorkspace.didActivateApplicationNotification` and closes
    /// the panel when another app is foregrounded (unless an overlay is active).
    func setupWorkspaceObserver() { observers?.setupWorkspaceObserver() }

    // MARK: - Screen observer

    /// Registers for display-topology changes so the live height cap and the
    /// current frame stay correct when a display is added, removed, or rescaled.
    func setupScreenObserver() { observers?.setupScreenObserver() }

    // MARK: - Outside-click monitor

    /// Installs a global `NSEvent` monitor for left/right mouse-down events.
    /// Closes or force-closes the panel depending on overlay state.
    func startEventMonitor() { observers?.startEventMonitor() }

    /// Removes the global mouse-down event monitor installed by `startEventMonitor()`.
    func stopEventMonitor() { observers?.stopEventMonitor() }
}
