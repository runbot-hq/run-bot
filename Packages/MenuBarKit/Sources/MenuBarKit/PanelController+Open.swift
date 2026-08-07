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
        // Refresh the height cap before onWillShow so that any KVO fire triggered
        // by the host's onWillShow callback (e.g. an @Observable property write
        // that immediately re-triggers SwiftUI layout) runs applyMeasuredSize
        // against the current session's cap, not the previous session's stale value.
        limits.maxContentHeight = liveMaxContentHeight()
        onWillShow?()
        mbkLog("PanelController", "onWillShow fired")
        mbkLog("PanelController", "openPanel -- maxContentHeight=\(limits.maxContentHeight)")

        lastContentSize = nil
        onWillCloseFired = false
        // hasOpenedOnce = true must be set before applyFrame — applyFrame's guard
        // requires it. It is set here rather than in setup() so that applyFrame
        // silently no-ops on any spurious pre-open KVO or invalidation call.
        // ❌ Do NOT move this assignment earlier or add a precondition in applyFrame —
        //    the silent no-op before first open is intentional defensive behaviour.
        hasOpenedOnce = true
        // Capture anchor snapshot while the status item is guaranteed onscreen.
        // Without this, a retracted menu bar moves the status item's window
        // offscreen, yielding a bogus anchor (#2447).
        captureAnchor()
        let ics = hostingController.view.intrinsicContentSize
        // Use preferredContentSize if KVO already fired (e.g. pre-show layout pass).
        // Falls back to FALLBACK only if not yet populated — KVO will correct it
        // once the view lays out in the live window.
        let pcs = hostingController.preferredContentSize
        mbkLog("PanelController", "openPanel PRE-SHOW -- preferredContentSize=\(pcs) intrinsicContentSize=\(ics)")
        if pcs.width > 0, pcs.height > 0 {
            mbkLog("PanelController", "openPanel -- applying pre-show preferredContentSize")
            let cap = limits.maxContentHeight // already set two lines above — avoid redundant screen lookup
            let content = MBKPanelGeometry.clampContent(
                pcs,
                minWidth: 1,
                maxWidth: liveMaxContentWidth(),
                maxHeight: cap
            )
            applyFrame(content: content, reason: "PRE-SHOW")
        } else {
            let fallback = MBKPanelGeometry.clampContent(
                MBKPanelMetrics.fallbackContentSize,
                minWidth: 1,
                maxWidth: liveMaxContentWidth(),
                maxHeight: limits.maxContentHeight  // already set at top of openPanel()
            )
            mbkLog("PanelController", "openPanel -- FALLBACK clamped=(\(fallback.width),\(fallback.height))")
            applyFrame(content: fallback, reason: "FALLBACK")
        }

        setButtonHighlight(true)
        mbkLog("MenuBarLease", "pre-activate -- visible=\(NSMenu.menuBarVisible()) options=\(NSApp.presentationOptions.rawValue)")
        NSApp.activate(ignoringOtherApps: true)
        menuBarVisibilityLease.acquire()
        panel.orderFrontRegardless()
        panel.makeKey()
        mbkLog("PanelController", "openPanel -- panel shown frame=\(panel.frame)")

        // Trigger first layout pass so preferredContentSize populates and KVO fires.
        // This intentionally runs AFTER orderFrontRegardless — the frame guarantee
        // ("frame applied before the window appears") is satisfied above by the
        // PRE-SHOW / FALLBACK applyFrame call. layoutSubtreeIfNeeded here is not
        // part of the positioning path; it exists only to prime the KVO pipeline.
        hostingController.view.layoutSubtreeIfNeeded()
        mbkLog("PanelController", "openPanel -- layoutSubtreeIfNeeded done")

        startEventMonitor()

        // Next-run-loop reinforcement: NSApp.activate() can apply presentation
        // options asynchronously, so re-acquire the lease after one actor hop.
        // Idempotent — does not overwrite the saved options from the direct call.
        Task { @MainActor [weak self] in
            guard let self, self.isShown else { return }
            self.menuBarVisibilityLease.acquire()
            NSMenu.setMenuBarVisible(true)
            mbkLog(
                "MenuBarLease",
                "reinforce -- visible=\(NSMenu.menuBarVisible()) active=\(self.menuBarVisibilityLease.isActive)"
            )
        }

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
        // Release the menu-bar visibility lease after the panel is ordered out.
        // This restores the exact presentation options captured at open time.
        menuBarVisibilityLease.release()
        // Deliberately reset both gate flags here even though they are nominally
        // owned by MBKAnchoredSheet, mbkOpenFilePicker, and MBKAlertModifier.
        // This is safe because every close path that reaches teardown has already
        // closed all child windows (forceClose iterates panel.childWindows before
        // calling teardown; performClose is gated on !overlayGate.hasActiveOverlay
        // so it only runs when the gate is already clear). By the time teardown
        // runs, no overlay is alive to race against this reset. The reset is a
        // safety net for the edge case where a completion handler never fires
        // (e.g. picker cancelled by the system), which would otherwise leave the
        // gate permanently armed and block all future closes.
        // Note: on the performClose path this reset is always a no-op —
        // performClose is gated on !overlayGate.hasActiveOverlay so the gate
        // is already false before teardown runs. The safety-net purpose only
        // applies on the forceClose path (child windows already closed above).
        // Note: on the forceClose path, all child windows are explicitly closed and
        // removed BEFORE teardown() is called (see forceClose() above), so by the
        // time this reset runs no overlay is alive to race against it. The reset
        // is therefore always safe on both close paths.
        // Guarded to avoid firing didSet (and its mbkLog) spuriously when the
        // gate is already clear — which is always the case on the performClose path.
        if overlayGate.hasActiveOverlay { overlayGate.hasActiveOverlay = false }
        if overlayGate.hasFilePickerOverlay { overlayGate.hasFilePickerOverlay = false }
        // Invalidate the anchor snapshot on close — the next open will capture a fresh one.
        anchorSnapshot = nil
        onWillCloseFired = false
        lastContentSize = nil
        mbkLog("PanelController", "panel closed wasForced=\(wasForced)")
    }

    // MARK: - Highlight

    /// Drives the status-button's pressed appearance while the panel is open.
    ///
    /// Arms/disarms the `MBKStatusBarButton.isPanelOpen` guard before calling
    /// `highlight(_:)`. The guard must be set first on both paths:
    /// - open (`isOn = true`): arm first → highlight(true) goes through → future
    ///   AppKit-internal highlight(false) calls are swallowed.
    /// - close (`isOn = false`): disarm first → highlight(false) goes through → button clears.
    ///
    /// Uses `highlight(_:)` rather than `isHighlighted`: `isHighlighted` is reset by
    /// AppKit as soon as the panel takes key status. `highlight(_:)` writes directly
    /// to the cell — but is still overridden by AppKit's internal tracking callbacks,
    /// which is exactly what `MBKStatusBarButton` guards against. See #2440.
    func setButtonHighlight(_ isOn: Bool) {
        // Cast succeeds in all normal operation — setupStatusItem calls
        // object_setClass(button, MBKStatusBarButton.self) unconditionally.
        // Failure here means that swap silently did not run (e.g. AppKit changed
        // NSStatusBarButton's class hierarchy). See injectCellSubclass in
        // MBKStatusBarButton.swift for the full swap sequence.
        let mbkBtn = statusItem?.button as? MBKStatusBarButton
        mbkLog("PanelController", "setButtonHighlight -- isOn=\(isOn) castOK=\(mbkBtn != nil) isPanelOpen=\(mbkBtn?.isPanelOpen ?? false)")

        // assertionFailure traps in debug builds and continues in release.
        // The highlight(isOn) call below it is intentional degraded-mode
        // behaviour: the button flickers on every open/close but there is no
        // crash. This ordering (assert, then degrade, then return) is correct.
        guard let mbkBtn else {
            assertionFailure("setButtonHighlight: statusItem.button is not MBKStatusBarButton — object_setClass swap failed at setup. Highlight guard is disarmed.")
            statusItem?.button?.highlight(isOn)
            return
        }

        // isPanelOpen must be set BEFORE highlight(_:) on both open and close paths.
        // See CALL-SITE CONTRACT in MBKStatusBarButton.swift.
        // mbkBtn is non-nil here (guard above); calling directly makes the
        // ordering contract structurally unambiguous.
        mbkBtn.isPanelOpen = isOn
        // Dispatches to MBKStatusBarButton.highlight(_:) via ObjC dynamic
        // dispatch — the ISA swap in setupStatusItem guarantees this even
        // though the static type at the call site is NSStatusBarButton.
        mbkBtn.highlight(isOn)
        mbkLog("PanelController", "setButtonHighlight -- done isPanelOpen=\(mbkBtn.isPanelOpen) buttonClass=\(type(of: mbkBtn as AnyObject))")
    }
}
