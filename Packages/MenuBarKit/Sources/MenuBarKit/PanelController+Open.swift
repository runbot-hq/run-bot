// PanelController+Open.swift
// MenuBarKit
//
// Open/close logic for MBKPanelController.
//
// CLOSE PATHS — all funnel into teardown:
//   performClose()  — gated normal close
//   forceClose()    — outside click while sheet live
//   teardown(wasForced:) — single place that fires onWillClose, stops monitors

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
        mbkLog("PanelController", "panel orderFront frame=\(panel.frame)")

        // Force SwiftUI to settle now that the view has a window.
        // onGeometryChange fires synchronously during this pass,
        // so applyMeasuredSize will be called before we reach the FALLBACK check.
        mbkLog("PanelController", "openPanel -- calling layoutSubtreeIfNeeded to trigger onGeometryChange")
        hostingController.view.layoutSubtreeIfNeeded()
        mbkLog("PanelController", "openPanel -- layoutSubtreeIfNeeded done, lastContentSize=\(String(describing: lastContentSize))")

        if lastContentSize == nil {
            mbkLog("PanelController", "openPanel -- onGeometryChange did not fire, using FALLBACK")
            let size = MBKPanelController.fallbackContentSize
            applyFrame(content: size, reason: "FALLBACK")
            lastContentSize = nil  // let the first real measurement override FALLBACK
        } else {
            mbkLog("PanelController", "openPanel -- onGeometryChange fired successfully, no FALLBACK needed")
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
