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
    ///
    /// The frame is computed and applied *before* `orderFront`, so the panel is
    /// never visible at a stale size or position — the class of bug that the old
    /// pre-show seed plus post-show reposition dance was trying (and failing) to
    /// paper over.
    func openPanel() {
        // setup() must be called before any open attempt. A nil panel/coalescer/limits
        // here means setup() was skipped — that is a programmer error and should crash
        // loudly with a clear attribution, not silently no-op or crash at the force-
        // unwraps below with no context.
        precondition(isSetUp, "openPanel() called before setup() — call setup() on MBKPanelController first")
        // statusItem?.button is the only legitimate optional (status item may be absent
        // in testing or before NSStatusBar assignment).
        guard statusItem?.button != nil else { return }
        let panel = panel!
        let coalescer = coalescer!
        let limits = limits!
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
        // NSApp.activate() — no-argument form, intentional post-deprecation replacement
        // for activate(ignoringOtherApps: true) which is deprecated macOS 14+.
        //
        // REVIEWER NOTE — this does NOT steal focus from other apps the way the old
        // activate(ignoringOtherApps: true) did. The no-arg form only activates if the
        // app is already the frontmost process or is about to become it via the panel.
        // .nonactivatingPanel keeps the previous app from being disturbed at the AppKit
        // level; NSApp.activate() here ensures our own process is ready to receive key
        // events for text fields inside the panel.
        //
        // makeKey() is belt-and-suspenders: becomesKeyOnlyIfNeeded = false on MBKPanel
        // means orderFrontRegardless already makes the panel key. Both lines have been
        // device-tested and are load-bearing for text-field focus on the first click.
        // Do not remove either without a full device test of text-field interaction.
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
    ///
    /// ORDERING — do not reorder without re-reading `fireOnWillClose`:
    /// `onWillClose(wasForced: true)` fires first so the adopter can snapshot and
    /// tear down its sheet state; child windows are detached before teardown so
    /// the panel can close cleanly.
    ///
    /// NOTE: Neither `hasActiveOverlay` nor `hasFilePickerOverlay` is cleared here.
    /// The event monitor only reaches `forceClose()` when `hasFilePickerOverlay` is
    /// false — the file-picker branch returns early. `teardown` is the authoritative
    /// reset for both flags.
    ///
    /// WHY THE GATE IS NOT CLEARED EARLY (before `teardown`):
    /// Clearing here and again in `teardown` would open a window where a synchronous
    /// re-arm of the gate from a child-window close `onChange` goes undetected —
    /// `teardown` would then clear a gate the adopter just armed, leaving the next
    /// open/close cycle with no overlay protection. A single authoritative reset in
    /// `teardown` avoids that race entirely.
    func forceClose() {
        guard isShown else { return }
        fireOnWillClose(wasForced: true)
        if let panel {
            // WHY WE DO NOT GUARD child ITERATION WITH child.isVisible:
            //   The TOCTOU race in MBKSheetAnchorTask (see AnchoredSheet.swift Known
            //   Limitations) can leave a dangling entry in childWindows after the
            //   sheet has already been dismissed. `isVisible` cannot tell that ghost
            //   apart from a real sheet that is animating out, and skipping a real
            //   sheet would leak an orphaned window. Detaching and closing every
            //   child unconditionally is a no-op for already-closing windows.
            //
            // REVIEWER NOTE — `panel.childWindows ?? []` is not redundant.
            //   NSPanel.childWindows is `[NSWindow]?` and returns nil (not an empty
            //   array) when no children are attached. The `?? []` guard makes the
            //   loop a clean no-op in that case rather than a force-unwrap crash.
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

    /// The single close implementation: monitors, highlight, order out, reset.
    /// - Parameter wasForced: Whether this close came from the force path.
    ///
    /// CONTRACT: callers MUST call `fireOnWillClose(wasForced:)` before `teardown`.
    /// `teardown` does NOT call `fireOnWillClose` itself — the callback must fire
    /// before gate/window teardown so adopters can snapshot state while it is still
    /// valid. `assertionFailure` enforces this contract loudly in debug and test builds.
    /// In release builds, if the contract is violated, `teardown` calls
    /// `fireOnWillClose` itself as a safe fallback — degraded behaviour rather
    /// than a production crash.
    ///
    /// `assertionFailure` (not `precondition`) is deliberate: a process termination
    /// in a release build from an unforeseen close path is a worse outcome than a
    /// mis-sequenced `onWillClose`. The fallback above keeps the gate and close
    /// cycle consistent in production while still crashing loudly in debug.
    /// Both current callers (`performClose`, `forceClose`) are verified safe — each
    /// guards `isShown` before calling `fireOnWillClose`, and `isShown` reflects
    /// `panel?.isVisible` which AppKit flips synchronously on `orderOut`.
    ///
    /// GATE RESET ORDERING: `teardown` is the authoritative and unconditional reset
    /// for both `hasActiveOverlay` and `hasFilePickerOverlay`. This means any overlay
    /// the adopter arms synchronously inside `onWillClose` (which fires before
    /// `teardown`) will be cleared by `teardown`. The documented adopter contract is:
    /// do not arm the gate inside `onWillClose`.
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

    /// Sets the status-bar button's highlighted state.
    /// - Parameter isOn: `true` while the panel is open.
    ///
    /// Uses `highlight(_:)` rather than `isHighlighted`. `isHighlighted` resets to
    /// `false` the moment the panel takes key status; `highlight(_:)` persists.
    func setButtonHighlight(_ isOn: Bool) {
        statusItem?.button?.highlight(isOn)
    }
}
