// PanelController+Open.swift
// MenuBarKit
//
// Open/close logic for MBKPanelController.
// See PanelController.swift file header for full design notes.
//
// CLOSE PATHS — all funnel into teardown:
//   performClose()       — gated normal close
//   forceClose()         — outside click while sheet live
//   teardown(wasForced:) — fires onWillClose, stops monitors, orders panel out

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

    func togglePanelInternal() {
        mbkLog("PanelController", "togglePanel -- isShown=\(isShown)")
        if isShown {
            performClose()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        precondition(isSetUp, "openPanel() called before setup()")
        guard statusItem?.button != nil else { return }

        mbkLog("PanelController", "openPanel -- calling onWillShow")
        onWillShow?()
        mbkLog("PanelController", "onWillShow fired")

        // Refresh cap for the current screen before anything is shown.
        limits.maxContentHeight = liveMaxContentHeight()
        mbkLog("PanelController", "openPanel -- maxContentHeight=\(limits.maxContentHeight)")

        lastContentSize = nil
        lastMeasuredSize = nil
        onWillCloseFired = false
        hasOpenedOnce = true

        let openSize = pendingContentSize ?? CGSize(width: 320, height: 240)
        let reason = pendingContentSize != nil ? "PRE-SHOW" : "FALLBACK"
        pendingContentSize = nil
        applyFrame(content: openSize, reason: reason)

        setButtonHighlight(true)
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        mbkLog("PanelController", "openPanel -- panel shown frame=\(panel!.frame)")

        // Trigger first layout pass so preferredContentSize populates and KVO fires.
        hostingController.view.layoutSubtreeIfNeeded()
        mbkLog("PanelController", "openPanel -- layoutSubtreeIfNeeded done")

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
            assertionFailure("teardown called without fireOnWillClose")
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
