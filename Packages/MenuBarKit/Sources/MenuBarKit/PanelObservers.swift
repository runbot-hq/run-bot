// PanelObservers.swift
// MenuBarKit
//
// Non-generic @MainActor class that owns the three observer/monitor registrations
// for MBKPanelController.
//
// WHY THIS EXISTS:
//   The observer closures previously lived in an extension on the generic class
//   MBKPanelController<Content: View>. Any `Task { @MainActor [weak self] }` in
//   that context captures `self` as `MBKPanelController<Content>`, which causes
//   the Swift compiler to spuriously flag `Content.Type` as non-Sendable under
//   [#SendableMetatypes] — even when Content is never referenced in the body.
//
//   Moving the closures into this plain non-generic class eliminates the generic
//   metatype from the capture context entirely. `Task { @MainActor [weak self] }`
//   here captures `MBKPanelObservers` — a plain, non-generic, @MainActor class.
//   No metatype, no warning. Concurrency model fully intact.

import AppKit

// MARK: - Observer target protocol

/// Internal protocol that `MBKPanelObservers` uses to call back into the controller
/// without holding a reference to the generic concrete type.
@MainActor
protocol MBKPanelObserverTarget: AnyObject {
    var isShown: Bool { get }
    var overlayGate: MBKOverlayGate { get }
    var hasSheetChildWindow: Bool { get }
    func performClose()
    func forceClose()
    func refreshForScreenChange()
    func applyMeasuredSize(_ size: CGSize)
    var hasOpenedOnce: Bool { get }
}

// MARK: - Observer manager

/// Owns workspace, screen, and outside-click observer registrations on behalf of
/// `MBKPanelController`. Kept non-generic so Task capture lists never carry
/// a generic metatype.
@MainActor
final class MBKPanelObservers {

    weak var controller: (any MBKPanelObserverTarget)?

    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?
    nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    nonisolated(unsafe) var eventMonitor: Any?

    init(controller: any MBKPanelObserverTarget) {
        self.controller = controller
    }

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
                guard let self, let controller = self.controller else { return }
                guard controller.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PanelController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !controller.overlayGate.hasActiveOverlay else {
                    mbkLog("PanelController", "workspace observer -- overlay active, keeping panel open")
                    return
                }
                mbkLog("PanelController", "workspace observer -- other app active, closing")
                controller.performClose()
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
                self?.controller?.refreshForScreenChange()
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
                guard let self, let controller = self.controller else { return }
                let hasOverlay = controller.overlayGate.hasActiveOverlay
                let hasFilePicker = controller.overlayGate.hasFilePickerOverlay
                mbkLog("PanelController",
                       "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PanelController", "event monitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = controller.hasSheetChildWindow
                        mbkLog("PanelController", "event monitor -- hasSheet=\(hasSheet)")
                        if hasSheet {
                            mbkLog("PanelController", "event monitor -- sheet overlay, force-closing")
                            controller.forceClose()
                        } else {
                            mbkLog("PanelController", "event monitor -- picker/alert overlay, ignoring outside click")
                        }
                    }
                } else {
                    mbkLog("PanelController", "event monitor -- no overlay, closing")
                    controller.performClose()
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

    // MARK: - KVO handler

    /// Called on `@MainActor` when `NSHostingController.preferredContentSize` changes.
    func handlePreferredContentSizeChange(_ newSize: CGSize) {
        guard let controller else { return }
        mbkLog(
            "PanelController",
            "KVO preferredContentSize -- new=(\(newSize.width),\(newSize.height)) isShown=\(controller.isShown) hasOpenedOnce=\(controller.hasOpenedOnce)"
        )
        controller.applyMeasuredSize(newSize)
    }
}
