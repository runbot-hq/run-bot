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
    ///
    /// The frame is computed and applied *before* `orderFront`, so the panel is
    /// never visible at a stale size or position — the class of bug that the old
    /// pre-show seed plus post-show reposition dance was trying (and failing) to
    /// paper over.
    func openPanel() {
        guard let panel, let coalescer, let limits, statusItem?.button != nil else { return }
        mbkLog("PanelController", "openPanel -- calling onWillShow")
        onWillShow?()
        mbkLog("PanelController", "onWillShow fired")

        limits.maxContentHeight = liveMaxContentHeight()
        lastContentSize = nil
        lastMeasuredSize = nil
        onWillCloseFired = false
        // Opens the gate on the frame pipeline. Before the first open the status
        // item has no on-screen position, so every launch-time layout pass would
        // write a frame anchored at the bottom-left of the display.
        hasOpenedOnce = true

        // chrome IS panel.contentView — do not re-insert it as a subview.
        // (It was previously lazily added here, which caused double-background.)

        // While the panel was off screen SwiftUI may never have laid out, in which
        // case `intrinsicContentSize` is still degenerate. Force one layout pass so
        // the measurement below is real on the very first open too.
        hostingView?.layoutSubtreeIfNeeded()

        // Synchronous measure + frame apply on this turn — see MBKSizeCoalescer.
        coalescer.flush()

        if lastContentSize == nil {
            // Measurement is still unavailable. Anchor the panel at an arbitrary
            // small size so the first frame the user sees is in the right place
            // and the right shape; the next measurement corrects it.
            let size = MBKPanelController.fallbackContentSize
            let fallbackHeight = limits.maxContentHeight > 0 ? min(size.height, limits.maxContentHeight) : size.height
            applyFrame(content: CGSize(width: size.width, height: fallbackHeight), reason: "FALLBACK")
        }

        setButtonHighlight(true)
        panel.orderFrontRegardless()
        // NSApp.activate() ensures the app is frontmost so the panel can receive key events.
        // Called before makeKey() deliberately — activate() is asynchronous in effect
        // (processed next run-loop turn), but becomesKeyOnlyIfNeeded = false on MBKPanel
        // means orderFrontRegardless already makes the panel key. makeKey() here is
        // belt-and-suspenders for the edge case where activate's run-loop processing
        // hasn't completed. No key-window race observed in practice.
        NSApp.activate()
        panel.makeKey()
        // Zero drawsBackground on every NSScrollView SwiftUI creates.
        // Deferred one run-loop tick: makeKeyAndOrderFront triggers SwiftUI’s first
        // layout pass asynchronously, so scroll views don’t exist until this fires.
        // A synchronous call here would be a no-op — no scroll views exist yet.
        DispatchQueue.main.async { [weak self] in
            self?.panel.contentView?.descendantScrollViews().forEach { $0.drawsBackground = false }
        }
        mbkLog("PanelController", "panel shown frame=\(panel.frame)")

        startEventMonitor()

        Task { @MainActor in
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
        teardown(wasForced: false)
    }

    /// Closes the panel out from under a live sheet after an outside click.
    ///
    /// ORDERING — do not reorder without re-reading `fireOnWillClose`:
    /// `onWillClose(wasForced: true)` fires first so the adopter can snapshot and
    /// tear down its sheet state; the gate is cleared next so `performClose`-style
    /// refusal is structurally impossible; child windows are detached last.
    ///
    /// NOTE: `hasFilePickerOverlay` is intentionally NOT cleared here. The event
    /// monitor only reaches `forceClose()` when it is false — the file-picker
    /// branch returns early. `teardown` is the authoritative reset for both flags.
    func forceClose() {
        guard isShown else { return }
        fireOnWillClose(wasForced: true)
        mbkLog("PanelController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let panel {
            // WHY WE DO NOT GUARD child ITERATION WITH child.isVisible:
            //   The TOCTOU race in MBKSheetAnchorTask (see AnchoredSheet.swift Known
            //   Limitations) can leave a dangling entry in childWindows after the
            //   sheet has already been dismissed. `isVisible` cannot tell that ghost
            //   apart from a real sheet that is animating out, and skipping a real
            //   sheet would leak an orphaned window. Detaching and closing every
            //   child unconditionally is a no-op for already-closing windows.
            for child in panel.childWindows ?? [] {
                mbkLog("PanelController", "forceClose -- closing child #\(child.windowNumber)")
                panel.removeChildWindow(child)
                child.close()
            }
        }
        teardown(wasForced: true)
    }

    /// Fires `onWillClose` exactly once per session, guarded by `onWillCloseFired`.
    /// - Parameter wasForced: Passed straight through to the adopter's callback.
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

    /// The single close implementation: callback, monitors, highlight, order out, reset.
    /// - Parameter wasForced: Whether this close came from the force path.
    private func teardown(wasForced: Bool) {
        fireOnWillClose(wasForced: wasForced)
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
    /// - Parameter isOn: `true` while the panel is open.
    ///
    /// Uses `highlight(_:)` rather than `isHighlighted`. `isHighlighted` resets to
    /// `false` the moment the panel takes key status; `highlight(_:)` persists.
    func setButtonHighlight(_ isOn: Bool) {
        statusItem?.button?.highlight(isOn)
    }
}
