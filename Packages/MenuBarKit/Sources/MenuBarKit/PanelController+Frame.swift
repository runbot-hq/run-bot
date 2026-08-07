// PanelController+Frame.swift
// MenuBarKit
//
// The one and only frame pipeline.
//
// Every frame the panel ever gets comes from `applyFrame(content:reason:)`.
// There is no second write path, no chrome-delta snapshot, and no per-session
// positional state beyond the anchor snapshot — the anchor is captured at
// openPanel() time and held until the next screen change or close.
// See #2447: without the snapshot, a retracted menu bar yields a bogus anchor.
//
// ❌ NEVER call `panel.setFrame` or `setFrameOrigin` anywhere else.
// ❌ NEVER set `hostingController.view.frame` by hand.
//
// LOGGING CONTRACT:
//   KVO      preferredContentSize fired with (w,h)
//   MEASURE  measured=(w,h) cap=…
//   WRITE    content=(w,h) anchorX=… topY=… frame=… clamped=…
//   SKIP     -- reason

import AppKit

/// Live anchor reading: where the panel must attach for one frame computation.
struct MBKAnchorReading {
    /// The horizontal centre of the status item button in screen coordinates.
    let anchorX: CGFloat
    /// The Y coordinate of the menu bar's bottom edge (top of panel attachment).
    let topY: CGFloat
    /// The visible frame of the screen containing the status item.
    let visibleFrame: CGRect
}

/// Frame computation and application for MBKPanelController.
extension MBKPanelController {

    // MARK: - Anchor

    /// Reads the current anchor position from the snapshot or live status item button.
    /// Returns the snapshot when one exists, falling back to a live read.
    /// WHY THE SNAPSHOT WINS: a retracted menu bar moves the status item's window
    /// offscreen; a live read during that window yields a bogus anchor (#2447).
    func readAnchor() -> MBKAnchorReading? {
        if let anchorSnapshot {
            return anchorSnapshot
        }
        return readAnchorLive()
    }

    /// Captures a fresh anchor snapshot. Call ONLY from openPanel(), before the
    /// pointer can leave the menu bar strip.
    func captureAnchor() {
        anchorSnapshot = readAnchorLive()
        mbkLog("PanelController", "captureAnchor -- \(String(describing: anchorSnapshot))")
    }

    /// Reads the current anchor position from the live status item button.
    /// Returns nil only if there is no button and no fallback screen.
    private func readAnchorLive() -> MBKAnchorReading? {
        guard let button = statusItem?.button else {
            mbkLog("PanelController", "readAnchor -- NO BUTTON")
            return nil
        }
        let buttonWindow = button.window
        let buttonScreen = buttonWindow?.screen
        guard let screen = buttonScreen ?? NSScreen.main else {
            mbkLog("PanelController", "readAnchor -- NO SCREEN")
            return nil
        }
        let visibleFrame = screen.visibleFrame

        // Coordinate system: macOS Y increases upward. screen.frame.maxY is the
        // physical top of the display. visibleFrame.maxY is the bottom edge of the
        // menu bar (the top of the usable area below it).
        //
        // Menu bar VISIBLE:     visibleFrame.maxY ≈ screen.frame.maxY - 24..28pt
        //                       → gap is large (~24pt) → <= 2 is FALSE → hidden = false ✅
        //
        // Menu bar AUTO-HIDDEN: OS expands visibleFrame toward the full screen height
        //                       → gap collapses to ~0pt → <= 2 is TRUE  → hidden = true  ✅
        //
        // buttonScreen == nil means the status item has no screen (e.g. hidden by
        // system crowding) — treat as hidden so topY falls back to visibleFrame.maxY.
        let hidden = buttonScreen == nil
            || abs(screen.frame.maxY - visibleFrame.maxY) <= 2

        let anchorX: CGFloat
        if let window = buttonWindow, window.frame.width > 0 {
            anchorX = window.frame.minX + button.frame.midX
            lastKnownAnchorX = anchorX
            // Normal path — no log needed
        } else if let cached = lastKnownAnchorX {
            anchorX = cached
            mbkLog("PanelController", "readAnchor -- CACHED fallback anchorX=\(anchorX)")
        } else {
            anchorX = visibleFrame.maxX - metrics.screenMargin
            mbkLog("PanelController", "readAnchor -- FALLBACK no cache anchorX=\(anchorX)")
        }

        let topY: CGFloat
        if hidden {
            // Menu bar is retracted or the button has no screen. visibleFrame.maxY
            // is the attachment edge (bottom of the menu bar). Adding status-bar
            // thickness would move the anchor to the physical top of the menu bar
            // area, which is incorrect — the panel must attach to the bar's bottom
            // edge. See #2447 — the anchor snapshot already captures the correct
            // position at open time, so this fallback only matters for the first
            // frame before the snapshot is captured.
            topY = visibleFrame.maxY
        } else if let window = buttonWindow, window.frame.minY > 0 {
            topY = window.frame.minY
        } else {
            topY = visibleFrame.maxY
        }
        mbkLog("PanelController", "readAnchorLive -- anchorX=\(anchorX) topY=\(topY) hidden=\(hidden) buttonWindow=\(buttonWindow != nil) buttonScreen=\(buttonScreen != nil)")
        return MBKAnchorReading(
            anchorX: anchorX,
            topY: topY,
            visibleFrame: visibleFrame
        )
    }

    /// Returns the visible frame of the screen currently hosting the status item,
    /// falling back to NSScreen.main, then a safe default.
    private func liveVisibleFrame() -> CGRect {
        statusItem?.button?.window?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Returns the maximum content height the panel may occupy on the current screen.
    func liveMaxContentHeight() -> CGFloat {
        let visible = liveVisibleFrame()
        let topY = readAnchor()?.topY ?? visible.maxY
        return MBKPanelGeometry.maxContentHeight(
            topY: topY,
            visibleFrame: visible,
            fraction: maxHeightFraction,
            metrics: metrics
        )
    }

    /// Returns the maximum content width the panel may occupy on the current screen.
    func liveMaxContentWidth() -> CGFloat {
        MBKPanelGeometry.maxContentWidth(visibleFrame: liveVisibleFrame(), metrics: metrics)
    }

    // MARK: - Measure

    /// Entry point from KVO on preferredContentSize and from invalidateContentSize().
    /// `measured` is the size AppKit read from SwiftUI under an unspecified proposal.
    func applyMeasuredSize(_ measured: CGSize) {
        guard hasOpenedOnce else {
            mbkLog("PanelController", "SKIP -- not shown yet, discarding (KVO will re-fire after layoutSubtreeIfNeeded)")
            return
        }
        guard isShown else {
            mbkLog("PanelController", "SKIP -- panel not shown, dropping post-close measurement")
            return
        }
        guard measured.width > 0, measured.height > 0 else {
            mbkLog("PanelController", "SKIP -- degenerate preferredContentSize (\(measured.width),\(measured.height))")
            return
        }
        let lastStr = lastContentSize.map { "(\($0.width),\($0.height))" } ?? "nil"
        mbkLog("PanelController", "applyMeasuredSize -- measured=(\(measured.width),\(measured.height)) isShown=\(isShown) lastContentSize=\(lastStr)")

        let anchor = readAnchor()
        let visibleFrame = anchor?.visibleFrame ?? liveVisibleFrame()
        let topY = anchor?.topY ?? visibleFrame.maxY
        let cap = MBKPanelGeometry.maxContentHeight(
            topY: topY,
            visibleFrame: visibleFrame,
            fraction: maxHeightFraction,
            metrics: metrics
        )
        let content = MBKPanelGeometry.clampContent(
            measured,
            minWidth: 1,
            maxWidth: liveMaxContentWidth(),
            maxHeight: cap
        )
        mbkLog(
            "PanelController",
            "applyMeasuredSize CLAMPED -- content=(\(content.width),\(content.height)) cap=\(cap)"
        )

        mbkLog("PanelController", "applyMeasuredSize DEDUP -- last=\(lastStr) new=(\(content.width),\(content.height))")
        // Dedup: suppress frame writes for content changes < 1pt (KVO noise suppression).
        if let last = lastContentSize,
           abs(last.width - content.width) < 1, abs(last.height - content.height) < 1 {
            mbkLog("PanelController", "SKIP -- content unchanged (\(content.width),\(content.height)) lastContentSize=\(lastContentSize.map { " (\($0.width),\($0.height))" } ?? "nil") SUPPRESSED")
            return
        }
        lastContentSize = content
        applyFrame(content: content, anchor: anchor, reason: "WRITE")
    }

    // MARK: - Apply

    /// Writes the panel frame derived from `content` and the live anchor.
    /// This is the **only** permitted call site for `panel.setFrame`.
    func applyFrame(content: CGSize, anchor: MBKAnchorReading? = nil, reason: String) {
        mbkLog("PanelController", "applyFrame ENTER -- content=(\(content.width),\(content.height)) reason=\(reason)")
        // Silent no-op when called before setup() or after teardown — intentional.
        // applyFrame can be invoked from KVO during a close sequence where panel
        // may already be nil. Use precondition(isSetUp) only at entry points that must
        // never fire pre-setup (e.g. openPanel).
        // `limits` is intentionally not bound here — it is only used for the maxContentHeight
        // cap, which is applied upstream in applyMeasuredSize and openPanel before applyFrame
        // is called. applyFrame is a pure frame writer that trusts its content parameter.
        guard let panel, hasOpenedOnce else { return }
        guard let anchor = anchor ?? readAnchor() else {
            mbkLog("PanelController", "\(reason) -- no anchor available, skipping frame")
            return
        }
        mbkLog("PanelController", "applyFrame ANCHOR -- anchorX=\(anchor.anchorX) topY=\(anchor.topY) visibleFrame=\(anchor.visibleFrame)")
        let layout = MBKPanelGeometry.layout(
            content: content,
            anchorX: anchor.anchorX,
            topY: anchor.topY,
            visibleFrame: anchor.visibleFrame,
            metrics: metrics
        )
        mbkLog("PanelController", "applyFrame LAYOUT -- layout.frame=\(layout.frame) wasClamped=\(layout.wasClamped)")

        mbkLog("PanelController", "applyFrame PRE-SET -- current panel.frame=\(panel.frame)")
        panel.setFrame(layout.frame, display: true)
        panel.invalidateShadow()
        mbkLog("PanelController", "applyFrame POST-SET -- panel.frame=\(panel.frame)")

        mbkLog(
            "PanelController",
            """
            \(reason) content=(\(content.width),\(content.height)) \
            anchorX=\(anchor.anchorX) topY=\(anchor.topY) \
            frame=\(layout.frame) clamped=\(layout.wasClamped)
            """
        )
    }

    /// Called by the screen observer when display parameters change.
    /// Recomputes the height cap and reapplies the current content size if shown.
    func refreshForScreenChange() {
        guard let limits else { return }
        // Invalidate the snapshot on screen change — the status item has moved
        // to a new display (or the display topology changed). The next anchor
        // read will capture a fresh snapshot via readAnchorLive().
        anchorSnapshot = nil
        guard isShown else {
            // If the panel is not shown, we're done — the next openPanel() will
            // capture a fresh anchor. Still update the height cap for next open.
            let cap = liveMaxContentHeight()
            mbkLog("PanelController", "refreshForScreenChange (closed) -- cap=\(cap) currentMax=\(limits.maxContentHeight)")
            if abs(cap - limits.maxContentHeight) >= 1 {
                limits.maxContentHeight = cap
            }
            return
        }
        // Panel is shown — recapture the anchor from the live position now
        // that the display topology has changed. The status item's window is
        // still onscreen so readAnchorLive() is safe.
        captureAnchor()
        // Re-acquire the SkyLight visibility override on the current display.
        // acquire(on:) handles same-display reassertion and old-display release.
        menuBarVisibilityLease.acquire(on: statusItem?.button?.window?.screen)
        let cap = liveMaxContentHeight()
        if abs(cap - limits.maxContentHeight) >= 1 {
            limits.maxContentHeight = cap
            mbkLog("PanelController", "refreshForScreenChange -- maxContentHeight updated to \(cap)")
        }
        guard isShown else { return }
        // lastContentSize is nil'd before re-reading preferredContentSize so the dedup
        // guard in applyMeasuredSize does not suppress the forced re-layout.
        // Ordering note: if a KVO Task hop is already queued when this runs (a
        // preferredContentSize change that arrived just before the screen change),
        // it will call applyMeasuredSize after this method completes with a
        // pre-screen-change size. Because lastContentSize is nil'd, the dedup guard
        // won't suppress it — producing one extra frame write with a stale content cap.
        // The practical consequence is a single unnecessary frame write; no visual
        // glitch occurs because the new cap is applied first. isShown guards the
        // blast radius to open-panel-only. No fix needed; noted for future ordering audits.
        lastContentSize = nil
        let size = hostingController.preferredContentSize
        if size.width > 0, size.height > 0 {
            mbkLog("PanelController", "refreshForScreenChange -- re-applying preferredContentSize=(\(size.width),\(size.height))")
            applyMeasuredSize(size)
        } else {
            mbkLog("PanelController", "refreshForScreenChange -- no pcs yet, waiting for KVO")
        }
    }
}
