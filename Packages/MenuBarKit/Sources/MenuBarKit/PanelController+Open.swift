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
//
// RE-ENTRANCY SAFETY — no isClosing flag is needed:
//   All three callers guard `isShown` (= panel?.isVisible) before calling
//   `fireOnWillClose` or `teardown`. AppKit flips `isVisible` to false
//   synchronously inside `orderOut` — not on the next compositor frame.
//   A second caller arriving on the same runloop turn (Task hop, workspace
//   notification, or adopter callback) will see isShown = false and
//   short-circuit at its guard. The `assertionFailure` in `teardown` cannot be
//   reached twice per cycle.

import AppKit

/// Open/close logic and status-button highlight for `MBKPanelController`.
extension MBKPanelController {

    // MARK: - State

    /// `true` while the panel is on screen.
    var isShown: Bool {
        panel?.isVisible ?? false
    }

    /// `true` when the panel has at least one child window (i.e. a sheet is attached).
    var hasSheetChildWindow: Bool {
        !(panel?.childWindows ?? []).isEmpty
    }

    // MARK: - Toggle / open

    /// Toggles the panel open or closed when the status-bar button is clicked.
    @objc func togglePanel() {
        mbkLog("PanelController", "togglePanel -- isShown=\(isShown)")
        if isShown {
            performClose()
        } else {
            openPanel()
        }
    }

    /// Shows the panel anchored under the status-bar button.
    func openPanel() {
        precondition(isSetUp, "openPanel() called before setup() — call setup() on MBKPanelController first")
        guard statusItem?.button != nil else { return }
        let panel = panel!
        mbkLog("PanelController", "openPanel -- calling onWillShow")
        onWillShow?()
        mbkLog("PanelController", "onWillShow fired")

        limits.maxContentHeight = liveMaxContentHeight()
        lastContentSize = nil
        lastMeasuredSize = nil
        onWillCloseFired = false
        hasOpenedOnce = true

        // Apply frame from preferredContentSize if KVO has already fired
        // (e.g. pre-show layout pass). If not yet available, use FALLBACK.
        let pcs = hostingController.preferredContentSize
        if pcs.width > 0, pcs.height > 0 {
            applyMeasuredSize(pcs)
        } else {
            let size = MBKPanelController.fallbackContentSize
            let fallbackHeight = limits.maxContentHeight > 0
                ? min(size.height, limits.maxContentHeight)
                : size.height
            applyFrame(content: CGSize(width: size.width, height: fallbackHeight), reason: "FALLBACK")
        }

        setButtonHighlight(true)
        panel.orderFrontRegardless()
        NSApp.activate()
        panel.makeKey()
        mbkLog("PanelController", "panel shown frame=\(panel.frame)")

        startEventMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }
            mbkLog("PanelController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PanelController", "onDidShow fired")
        }
    }

    // MARK: - Close

    /// Normal, gated close. Refused while any overlay (sheet, alert, picker) is live.
    func performClose() {
        guard isShown else { return }
        guard !overlayGate.hasActiveOverlay else {
            mbkLog("PanelController", "performClose -- overlay active, staying open")
            return
        }
        fireOnWillClose(wasForced: false)
        teardown(wasForced: false)
    }

    /// Closes the panel out from under a live sheet after an outside click.
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

    /// Fires `onWillClose` exactly once per session, guarded by `onWillCloseFired`.
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

    /// The single close implementation: monitors, highlight, order out, reset.
    private func teardown(wasForced: Bool) {
        if !onWillCloseFired {
            assertionFailure(
                "teardown called without a prior fireOnWillClose — call fireOnWillClose(wasForced:) first"
            )
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

    /// Sets the status-bar button's highlighted state.
    func setButtonHighlight(_ isOn: Bool) {
        statusItem?.button?.highlight(isOn)
    }
}
