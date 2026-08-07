// PanelObservers.swift
// MenuBarKit
//
// Non-generic @MainActor class that owns the three observer/monitor registrations
// for MBKPanelController.
//
// Escape is handled by MBKPanel.cancelOperation(_:), not by a monitor — the
// panel takes key status, so Escape reaches the responder chain normally.
// See Panel.swift for the cancelOperation(_:) implementation and design notes.
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

/// Internal coordination protocol between `MBKPanelObservers` and `MBKPanelController`.
/// **Not part of the public API.** Internal access is intentional — this protocol is a
/// private seam that lets the non-generic observer manager call back into the generic
/// controller without capturing its generic type parameter. Do not make it public.
@MainActor
protocol MBKPanelObserverTarget: AnyObject {
    /// Whether the panel is currently visible.
    var isShown: Bool { get }
    /// Gate that tracks active overlays (sheets, pickers, alerts).
    var overlayGate: MBKOverlayGate { get }
    /// Whether the panel currently has a sheet child window attached.
    var hasSheetChildWindow: Bool { get }
    /// Performs a normal close of the panel.
    func performClose()
    /// Force-closes the panel, dismissing any active overlay.
    func forceClose()
    /// Refreshes layout and frame after a display-topology change.
    func refreshForScreenChange()
    /// Applies a new measured content size to the panel frame.
    func applyMeasuredSize(_ size: CGSize)
    /// Releases the menu-bar hold during normal application termination.
    func releaseMenuBarHold()
}

// MARK: - Observer manager

/// Owns workspace, screen, and outside-click observer registrations on behalf of
/// `MBKPanelController`. Kept non-generic so Task capture lists never carry
/// a generic metatype.
@MainActor
final class MBKPanelObservers {

    /// The controller this observer set acts on behalf of.
    weak var controller: (any MBKPanelObserverTarget)?

    /// Token for the workspace active-application notification observer.
    private nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?
    /// Token for the screen-parameters change notification observer.
    private nonisolated(unsafe) var screenObserver: NSObjectProtocol?
    /// Token for the global mouse-down event monitor.
    private nonisolated(unsafe) var eventMonitor: Any?
    /// Token for the application-termination notification observer.
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    /// Creates an observer manager for the given controller.
    init(controller: any MBKPanelObserverTarget) {
        self.controller = controller
    }

    /// Removes all registered observers and monitors when the controller releases this instance.
    ///
    /// TEARDOWN PATHS — two mutually exclusive routes, no double-remove risk:
    ///   • Normal close: `stopEventMonitor()` removes and nils `eventMonitor` on @MainActor
    ///     before the controller could ever be deallocated (panel must be closed first).
    ///     When deinit subsequently fires, all three guards (`if let`) are nil — no-ops.
    ///   • Teardown while open (e.g. app termination with panel visible): `stopEventMonitor()`
    ///     was never called, so `eventMonitor` is non-nil and deinit removes it here.
    ///
    /// There is no race: `stopEventMonitor()` and this deinit both execute on @MainActor
    /// (deinit is triggered by the controller’s release, which only happens on @MainActor).
    /// `nonisolated(unsafe)` on the token vars is safe for the same reason — every live
    /// read/write is actor-isolated; `nonisolated` is required only to satisfy the compiler
    /// for the deinit context.
    nonisolated
    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = terminationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Workspace observer

    /// Registers for `NSWorkspace.didActivateApplicationNotification` and closes
    /// the panel when another app is foregrounded (unless an overlay is active).
    func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            // Evaluate the NSRunningApplication comparison on the notification thread
            // before the Task hop. NSRunningApplication is not Sendable; capturing
            // the resulting Bool (Sendable) avoids crossing an isolation boundary
            // with a non-Sendable type.
            let isSelfActivation = (notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication) == NSRunningApplication.current
            Task { @MainActor [weak self] in
                guard let self, let controller = self.controller else { return }
                guard controller.isShown else { return }
                guard !isSelfActivation else {
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

    // MARK: - Termination observer

    /// Registers for `NSApplication.willTerminateNotification` and releases the
    /// menu-bar hold synchronously on `.main`.
    ///
    /// This is a separate observer (not merged into the workspace observer) because
    /// termination is not an app-switch event. The workspace observer fires on
    /// `NSWorkspace.didActivateApplicationNotification` and does not fire during
    /// termination. A dedicated termination observer is required to release the
    /// process-external SkyLight visibility override before the process exits.
    ///
    /// The callback runs synchronously on `.main` to ensure the SkyLight
    /// visibility override is cleared before the process exits. An async Task
    /// may not execute before the process terminates.
    func setupTerminationObserver() {
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.controller?.releaseMenuBarHold()
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
    /// A nil `controller` here means the controller was released before this KVO fire
    /// arrived — intentional silent-drop during teardown.
    func handlePreferredContentSizeChange(_ newSize: CGSize) {
        guard let controller else { return }
        mbkLog(
            "PanelController",
            "KVO preferredContentSize -- new=(\(newSize.width),\(newSize.height)) isShown=\(controller.isShown)"
        )
        controller.applyMeasuredSize(newSize)
    }
}
