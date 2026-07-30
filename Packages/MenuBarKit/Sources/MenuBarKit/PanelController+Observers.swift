// PanelController+Observers.swift
// MenuBarKit
//
// Workspace app-switch observer, screen-parameter observer, and outside-click
// monitor for MBKPanelController.
//
// Escape is handled by MBKPanel.cancelOperation(_:), not by a monitor — the
// panel takes key status, so Escape reaches the responder chain normally.
// See PanelController.swift file header for full design notes.

import AppKit

/// Observers and event monitors for `MBKPanelController`.
extension MBKPanelController {

    // MARK: - Workspace observer

    /// Registers for `NSWorkspace.didActivateApplicationNotification` and closes
    /// the panel when another app is foregrounded (unless an overlay is active).
    func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PanelController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !self.overlayGate.hasActiveOverlay else {
                    mbkLog("PanelController", "workspace observer -- overlay active, keeping panel open")
                    return
                }
                mbkLog("PanelController", "workspace observer -- other app active, closing")
                self.performClose()
            }
        }
    }

    // MARK: - Screen observer

    /// Registers for display-topology changes so the live height cap and the
    /// current frame stay correct when a display is added, removed, or rescaled.
    func setupScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshForScreenChange()
            }
        }
    }

    // MARK: - Outside-click monitor

    /// Installs a global `NSEvent` monitor for left/right mouse-down events.
    /// Closes or force-closes the panel depending on overlay state.
    func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PanelController",
                       "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PanelController", "event monitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = self.hasSheetChildWindow
                        mbkLog("PanelController", "event monitor -- hasSheet=\(hasSheet)")
                        if hasSheet {
                            mbkLog("PanelController", "event monitor -- sheet overlay, force-closing")
                            self.forceClose()
                        } else {
                            mbkLog("PanelController", "event monitor -- picker/alert overlay, ignoring outside click")
                        }
                    }
                } else {
                    mbkLog("PanelController", "event monitor -- no overlay, closing")
                    self.performClose()
                }
            }
        }
        mbkLog("PanelController", "event monitor started")
    }

    /// Removes the global mouse-down event monitor installed by `startEventMonitor()`.
    func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PanelController", "event monitor stopped")
    }
}
