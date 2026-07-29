// PanelController+Open.swift
// MenuBarKit
//
// Open/close logic for MBKPanelController.
// See PanelController.swift file header for full design notes.
//
// CLOSE PATHS — there are exactly three, and they all funnel into `teardown`:
//   performClose()  — gated normal close (status-item click, Escape, app switch,
//                     outside click with no overlay). Refuses while an overlay is live.
//   forceClose()    — outside click while a sheet is live. Clears the gate and
//                     detaches child windows first, so it can never be refused.
//   teardown(wasForced:) — the single place that fires onWillClose, stops the
//                     monitors, unhighlights the button, and orders the panel out.

import AppKit

extension MBKPanelController {

    // MARK: - State

    var isShown: Bool {
        panel?.isVisible ?? false
    }

    var hasSheetChildWindow: Bool {
        !(panel?.childWindows ?? []).isEmpty
    }

    // MARK: - Toggle / open

    @objc func togglePanel() {
        mbkLog("PanelController", "togglePanel -- isShown=\(isShown)")
        if isShown {
            performClose()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        precondition(isSetUp, "openPanel() called before setup() — call setup() on MBKPanelController first")
        guard statusItem?.button != nil else { return }
        let panel = panel!
        mbkLog("PanelController", "openPanel -- calling onWillShow")
        onWillShow?()
        mbkLog("PanelController", "onWillShow fired")

        lastContentSize = nil
        lastMeasuredSize = nil
        onWillCloseFired = false
        hasOpenedOnce = true

        setButtonHighlight(true)
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        mbkLog("PanelController", "panel shown frame=\(panel.frame)")

        // Force a layout now that the view has a window, then read the actual
        // preferredContentSize that SwiftUI computed. Before orderFront the view
        // has never laid out, so preferredContentSize is (0,0).
        hostingController.view.layoutSubtreeIfNeeded()
        let measured = hostingController.preferredContentSize
        if measured.width > 0, measured.height > 0 {
            applyMeasuredSize(measured)
        }

        if lastContentSize == nil {
            let size = MBKPanelController.fallbackContentSize
            let fallbackHeight = size.height
            applyFrame(content: CGSize(width: size.width, height: fallbackHeight), reason: "FALLBACK")
        }

        startEventMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }
            mbkLog("PanelController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PanelController", "onDidShow fired")
        }
    }

    // MARK: - Close

    func performClose() {
        guard isShown else { return }
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PanelController", "performClose -- overlay active, staying open")
            return
        }
        fireOnWillClose(wasForced: false)
        teardown(wasForced: false)
    }

    func forceClose() {
        guard isShown else { return }
        fireOnWillClose(wasForced: true)
        if let panel {
            for child in panel.childWindows ?? [] {
                mbkLog("PanelController", "forceClose -- closing child #\(child.windowNumber)")
                panel.removeChildWindow(child)
                child.close()
            }
        }
        teardown(wasForced: true)
    }

    func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else {
            mbkLog("PanelController", "onWillClose already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PanelController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PanelController", "onWillClose fired")
    }

    private func teardown(wasForced: Bool) {
        if !onWillCloseFired {
            assertionFailure("teardown called without a prior fireOnWillClose — call fireOnWillClose(wasForced:) first")
            fireOnWillClose(wasForced: wasForced)
        }
        stopEventMonitor()
        setButtonHighlight(false)
        panel?.orderOut(nil)
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        lastContentSize = nil
        lastMeasuredSize = nil
        mbkLog("PanelController", "panel closed wasForced=\(wasForced)")
    }

    // MARK: - Highlight

    func setButtonHighlight(_ isOn: Bool) {
        statusItem?.button?.highlight(isOn)
    }
}
