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

        logHighlightState("openPanel PRE-highlight")

        setButtonHighlight(true)
        logHighlightState("openPanel -- setButtonHighlight(true) done")

        panel.orderFrontRegardless()
        logHighlightState("openPanel -- orderFrontRegardless done")

        panel.makeKey()
        logHighlightState("openPanel -- makeKey() done")

        mbkLog("PanelController", "openPanel -- panel shown frame=\(panel.frame)")

        // Trigger first layout pass so preferredContentSize populates and KVO fires.
        // This intentionally runs AFTER orderFrontRegardless — the frame guarantee
        // ("frame applied before the window appears") is satisfied above by the
        // PRE-SHOW / FALLBACK applyFrame call. layoutSubtreeIfNeeded here is not
        // part of the positioning path; it exists only to prime the KVO pipeline.
        hostingController.view.layoutSubtreeIfNeeded()
        logHighlightState("openPanel -- layoutSubtreeIfNeeded done")

        startEventMonitor()

        Task { @MainActor [weak self] in
            guard let self else { return }
            logHighlightState("onDidShow Task hop")
            mbkLog("PanelController", "onDidShow -- panel.frame=\(panel?.frame ?? .zero) preferredContentSize=\(hostingController.preferredContentSize)")
            mbkLog("PanelController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PanelController", "onDidShow fired")
            logHighlightState("onDidShow fired")
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
        logHighlightState("teardown -- before setButtonHighlight(false)")
        setButtonHighlight(false)
        logHighlightState("teardown -- after setButtonHighlight(false)")
        panel?.orderOut(nil)
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
        onWillCloseFired = false
        lastContentSize = nil
        mbkLog("PanelController", "panel closed wasForced=\(wasForced)")
    }

    // MARK: - Highlight

    /// Drives the status-button's pressed "pill" appearance while the panel is open.
    ///
    /// #2440 REVISED APPROACH: we no longer call `NSButton.highlight(_:)` or
    /// `isHighlighted` at all — AppKit's own highlight mechanism is disabled via
    /// `highlightsBy = []` in `setupStatusItem()`. Instead this toggles the
    /// opacity/color of `highlightPillLayer`, a plain `CALayer` that only this
    /// method (and setupStatusItem's initial creation) ever touches.
    ///
    /// Why the previous approach (subclassing + `object_setClass`, guarding
    /// `highlight(_:)`) failed: AppKit's `panel.makeKey()` and app-switch reset
    /// paths mutate the button *cell's* internal highlight state directly, never
    /// routing through the public `NSButton.highlight(_:)` method our override
    /// intercepted. There was nothing for the override to catch. By disabling
    /// `highlightsBy` entirely and owning 100% of the pressed-appearance drawing
    /// ourselves on a layer AppKit never references, there is no shared state
    /// left for any AppKit-internal code path to reset out from under us.
    ///
    /// cornerRadius is recomputed on every call (not just at setup) in case the
    /// button's frame changed between sessions (e.g. status item resized after
    /// a screen/resolution change) — keeps the pill shape correct if that happens.
    func setButtonHighlight(_ isOn: Bool) {
        guard let button = statusItem?.button else {
            mbkLog("PanelController", "⚠️ setButtonHighlight(\(isOn)) -- statusItem.button is nil, nothing to draw")
            return
        }
        guard let pill = highlightPillLayer else {
            mbkLog("PanelController", "⚠️ setButtonHighlight(\(isOn)) -- highlightPillLayer is nil,"
                + " was setupStatusItem() run? Falling back to no-op -- button will show no pressed state.")
            return
        }
        mbkLog("PanelController",
            "setButtonHighlight(\(isOn)) -- ENTER pill.opacity(before)=\(pill.opacity) bounds=\(button.bounds)")

        pill.cornerRadius = button.bounds.height / 2
        pill.backgroundColor = isOn
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.22).cgColor
            : NSColor.clear.cgColor
        pill.frame = button.bounds
        pill.opacity = isOn ? 1 : 0

        mbkLog("PanelController",
            "setButtonHighlight(\(isOn)) -- EXIT  pill.opacity(after)=\(pill.opacity)"
            + " pill.frame=\(pill.frame) pill.cornerRadius=\(pill.cornerRadius)"
            + " AppKit isHighlighted(unused, logged for comparison)=\(button.isHighlighted)")
    }

    /// Debug helper: logs the self-drawn pill state alongside AppKit's own
    /// (unused, but informative) `isHighlighted` so any divergence or unexpected
    /// AppKit interference is visible in the log stream. Call at every
    /// significant step of the open/close sequence — cheap, DEBUG-only cost
    /// via mbkLogHandler's default no-op-in-release behaviour.
    private func logHighlightState(_ context: String) {
        guard let button = statusItem?.button else {
            mbkLog("PanelController", "[highlight] \(context) -- button is nil")
            return
        }
        let pillOpacity = highlightPillLayer?.opacity ?? -1
        let pillColor = highlightPillLayer?.backgroundColor
        mbkLog("PanelController",
            "[highlight] \(context) -- pillOpacity=\(pillOpacity) pillColor=\(String(describing: pillColor))"
            + " appkitIsHighlighted=\(button.isHighlighted) buttonBounds=\(button.bounds)")
    }
}
