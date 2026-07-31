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

extension MBKPanelController: MBKPanelObserverTarget {}

// MARK: - Observer lifecycle bridge

extension MBKPanelController {

    func setupWorkspaceObserver() { observers.setupWorkspaceObserver() }
    func setupScreenObserver()    { observers.setupScreenObserver() }
    func startEventMonitor()      { observers.startEventMonitor() }
    func stopEventMonitor()       { observers.stopEventMonitor() }
}
