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

    @objc func togglePanel() {
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

        // Use preferredContentSize if KVO already fired (e.g. pre-show layout pass).
        // Falls back to FALLBACK only if not yet populated — KVO will correct it
        // once the view lays out in the live window.
        let pcs = hostingController.preferredContentSize
        mbkLog("PanelController", "openPanel -- preferredContentSize=(\(pcs.width),\(pcs.height))")
        if pcs.width > 0, pcs.height > 0 {
            mbkLog("PanelController", "openPanel -- applying pre-show preferredContentSize")
            applyMeasuredSize(pcs)
        } else {
            let fallback = MBKPanelController.fallbackContentSize
            let fallbackH = limits.maxContentHeight > 0
                ? min(fallback.height, limits.maxContentHeight)
                : fallback.height
            mbkLog("PanelController", "openPanel -- FALLBACK (\(fallback.width),\(fallbackH))")
            applyFrame(
                content: CGSize(width: fallback.width, height: fallbackH),
                reason: "FALLBACK"
            )
        }

        setButtonHighlight(true)
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        mbkLog("PanelController", "openPanel -- panel shown frame=\(panel!.frame)")

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
