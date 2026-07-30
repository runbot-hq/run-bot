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

/// Open/close and highlight behaviour for MBKPanelController.
extension MBKPanelController {

    // MARK: - State

    /// Whether the panel window is currently visible on screen.
    var isShown: Bool {
        panel?.isVisible ?? false
    }

    /// Whether the panel has any child windows (e.g. an active sheet).
    var hasSheetChildWindow: Bool {
        !(panel?.childWindows ?? []).isEmpty
    }

    // MARK: - Toggle / open

    /// Handles the status item button tap — opens if closed, closes if open.
    func togglePanelInternal() {
        mbkLog("PanelController", "togglePanel -- isShown=\(isShown)")
        if isShown {
            performClose()
        } else {
            openPanel()
        }
    }

    /// Opens the panel, positions it under the status item, and activates it.
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
        onWillCloseFired = false
        hasOpenedOnce = true
        let ics = hostingController.view.intrinsicContentSize
        let pcs2 = hostingController.preferredContentSize
        mbkLog("PanelController", "openPanel -- intrinsicContentSize=(\(ics.width),\(ics.height)) preferredContentSize=(\(pcs2.width),\(pcs2.height))")

        // Use preferredContentSize if KVO already fired (e.g. pre-show layout pass).
        // Falls back to FALLBACK only if not yet populated — KVO will correct it
        // once the view lays out in the live window.
        let pcs = hostingController.preferredContentSize
        mbkLog("PanelController", "openPanel PRE-SHOW -- preferredContentSize=\(pcs) intrinsicContentSize=\(hostingController.view.intrinsicContentSize)")
        if pcs.width > 0, pcs.height > 0 {
            mbkLog("PanelController", "openPanel -- applying pre-show preferredContentSize")
            let cap = liveMaxContentHeight()
            let content = MBKPanelGeometry.clampContent(
                CGSize(width: pcs.width, height: pcs.height - metrics.arrowHeight),
                minWidth: 1,
                maxWidth: liveMaxContentWidth(),
                maxHeight: cap
            )
            applyFrame(content: content, reason: "PRE-SHOW")
        } else {
            mbkLog("PanelController", "openPanel -- FALLBACK (320.0,240.0)")
            applyFrame(content: CGSize(width: 320, height: 240), reason: "FALLBACK")
        }

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
            mbkLog("PanelController", "onDidShow -- panel.frame=\(panel?.frame ?? .zero) preferredContentSize=\(hostingController.preferredContentSize)")
            mbkLog("PanelController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PanelController", "onDidShow fired")
        }
    }

    // MARK: - Close

    /// Closes the panel if no overlay is active.
    func performClose() {
        guard isShown else { return }
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PanelController", "performClose -- overlay active, staying open")
            return
        }
        fireOnWillClose(wasForced: false)
        teardown(wasForced: false)
    }

    /// Force-closes the panel and all child windows regardless of overlay state.
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

    /// Fires `onWillClose` exactly once per open session.
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

    /// Tears down the panel session: stops monitors, orders out, resets state.
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
        mbkLog("PanelController", "panel closed wasForced=\(wasForced)")
    }

    // MARK: - Highlight

    /// Highlights or un-highlights the status item button.
    func setButtonHighlight(_ isOn: Bool) {
        statusItem?.button?.highlight(isOn)
    }
}
