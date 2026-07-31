// PanelController+Observers.swift
// MenuBarKit
//
// Conforms MBKPanelController<Content> to MBKPanelObserverTarget and bridges
// observer lifecycle calls to MBKPanelObservers.
//
// The actual observer/monitor logic lives in PanelObservers.swift (non-generic
// @MainActor class) to avoid the spurious [#SendableMetatypes] warning that
// fires when Task { @MainActor [weak self] } captures a generic self.
//
// Escape is handled by MBKPanel.cancelOperation(_:), not by a monitor — the
// panel takes key status, so Escape reaches the responder chain normally.
// See PanelController.swift file header for full design notes.

import AppKit

// MARK: - MBKPanelObserverTarget conformance

/// Declares that `MBKPanelController` satisfies the `MBKPanelObserverTarget` protocol
/// so `MBKPanelObservers` can call back into the controller without a generic reference.
extension MBKPanelController: MBKPanelObserverTarget {}

// MARK: - Observer lifecycle bridge

/// Bridges observer setup/teardown calls from `MBKPanelController` to `MBKPanelObservers`.
extension MBKPanelController {

    /// Registers the workspace active-application observer via `MBKPanelObservers`.
    func setupWorkspaceObserver() { observers.setupWorkspaceObserver() }
    /// Registers the screen-parameters change observer via `MBKPanelObservers`.
    func setupScreenObserver() { observers.setupScreenObserver() }
    /// Installs the global outside-click event monitor via `MBKPanelObservers`.
    func startEventMonitor() { observers.startEventMonitor() }
    /// Removes the global outside-click event monitor via `MBKPanelObservers`.
    func stopEventMonitor() { observers.stopEventMonitor() }
}
