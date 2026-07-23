// PanelContainerView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - PanelContainerView
//
// Thin wrapper around the real panel content that adds a sheet-dim overlay
// AND reports the content's intrinsic size to the popover host.
//
// WHY THIS EXISTS (#1017 — NSPopover sheet dim):
// NSPopoverWindowFrame (the backing window of NSPopover) does not participate
// in AppKit's standard modal sheet dimming path. When a SwiftUI .sheet is
// presented, the parent popover content is NOT dimmed by the system.
//
// FIX: We observe the hosting NSWindow.sheets via a Task-based poll (the only
// reliable way without subclassing NSWindow) and overlay a semi-transparent
// black rectangle when sheets are present. The observed window is captured from
// this view hierarchy, not from NSApp.windows, so stale hidden popover windows
// cannot leave an invisible click-blocking overlay behind after a transient hide.
//
// ❌ NEVER remove the overlay — without it the popover content is fully
//    interactive behind an open sheet, which is confusing and buggy.
//
// ── SIZE REPORTING ───────────────────────────────────────────────────────────────────
//
// This view is the ACTIVE size-reporting path. It lives INSIDE the AnyView
// boundary created by NavigationShell.content, so its GeometryReader measures
// PanelMainView’s TYPED, .fixedSize()-constrained intrinsic size — not the
// proposed size echoed back from NSHostingController.
//
// HOW IT WORKS:
//   NavigationShellView injects the resize callback via the `panelSizeReporter`
//   environment key. This view reads that key and calls it from the
//   background(GeometryReader) on `content`, on both `.onAppear` and
//   `.onChange(of: geo.size)`.
//
//   This matches PopoverController.setupPopover() in runbot-hq/MenuBarKit PR #6:
//   pendingRootView.background(GeometryReader { ... .onAppear { applyContentSize }
//                                               ... .onChange { applyContentSize } })
//   — the key difference is PR #6 has a typed root view; RunBot uses the
//   environment key to cross the AnyView boundary.
//
// ❌ NEVER re-introduce a GeometryReader at NavigationShellView level — it is
//    outside the AnyView boundary and measures the proposed (frozen) size.
// ❌ NEVER re-introduce KVO on preferredContentSize — two competing paths.
//
// ── TRANSIENT HIDE / RESTORE ANIMATION INVARIANT ─────────────────────────────────
//
// PROBLEM (fixed, do not regress):
// When the user switches away from the app while a sheet is open, hidePanel()
// is called. hidePanel() sets panelVisibilityState.isOpen = false WITHOUT
// dismissing the sheet — the sheet NSWindow stays attached and alive.
// This fires onChange(isOpen) with open=false, which previously cleared
// isSheetActive = false. On restore, the poll task set it back to true, replaying
// the cover fade-in animation even though the sheet never closed.
//
// FIX:
// hidePanel() sets panelVisibilityState.isTransientHide = true BEFORE setting
// isOpen = false. onChange and the poll task guard both check isTransientHide and
// skip clearing isSheetActive when it is true. On full close (closePanel),
// isTransientHide is false, so isSheetActive is correctly cleared.
// On re-open, onChange(open=true) resets isTransientHide = false.
//
// SEQUENCE — transient hide while sheet is open:
//   hidePanel()  →  isTransientHide = true  →  isOpen = false
//   onChange(false): stopPolling(), isTransientHide=true so isSheetActive stays true
//   openPanel()  →  isOpen = true
//   onChange(true): isTransientHide = false, startPolling()
//   poll tick: window visible, sheet found, isSheetActive already true → no change, no animation ✅
//
// SEQUENCE — full close while sheet is open:
//   closePanel() →  isTransientHide stays false  →  isOpen = false
//   onChange(false): stopPolling(), isTransientHide=false so isSheetActive = false ✅
//
// ── POLL TASK GUARD SPLIT (do not re-split, fixed jitter)──────────────────────
//
// PROBLEM (fixed, do not regress):
// An earlier iteration split the guard into two: first guard hostWindow != nil,
// then guard isOpen && isVisible. When hostWindow was nil (it is delivered via
// DispatchQueue.main.async in WindowReader.makeNSView, so it arrives one runloop
// after the view appears), the first guard returned early with no state change.
// Meanwhile hostWindow was delivered, then the next tick found the sheet and set
// isSheetActive = true. But because the single-guard else branch no longer ran
// on the nil-window tick, the overlay appeared one tick later than expected,
// causing a visible flash/jitter on the very first sheet open.
//
// FIX: Keep the guard as a single atomic expression so the else branch runs
// consistently regardless of which condition fails. The else branch is where
// isTransientHide is checked before any state mutation.
//
// ── SLEEP-FIRST LOOP ORDER (do not change) ─────────────────────────────────
//
// The poll loop sleeps BEFORE executing the guard. hostWindow is delivered via
// DispatchQueue.main.async in WindowReader.makeNSView, so it is nil for at least
// one runloop after the view appears. Sleeping first matches the original
// Timer.scheduledTimer behaviour (first fire after 100ms, not immediately) and
// avoids an immediate guard-fail tick before hostWindow is populated.
//
// ── CANCELLATION: bare try on Task.sleep ───────────────────────────────────
//
// Task.sleep is called with bare `try`, not `try?`. When stopPolling() cancels
// the task mid-sleep, CancellationError propagates out of the loop immediately
// without executing a spurious post-cancel tick. `try?` would swallow the error
// and allow one extra iteration before Task.isCancelled is re-checked.
//
// ────────────────────────────────────────────────────────────────────────────

/// Wraps popover content, dims it when a SwiftUI sheet is active, and reports
/// its intrinsic size upward via the `panelSizeReporter` environment key.
struct PanelContainerView<Content: View>: View {
    /// The child view to wrap.
    let content: Content

    /// Legacy per-instance size callback — retained for call-site compatibility.
    /// The active size-reporting path is via `panelSizeReporter` from the environment.
    /// Defaults to a no-op so existing call sites compile without changes.
    var onSizeChange: (CGSize) -> Void = { _ in }

    /// Size-reporter injected by NavigationShellView via the environment.
    /// This is the ACTIVE path — called from the background(GeometryReader) on
    /// `content`, which is inside the AnyView boundary where intrinsic size is
    /// measurable. Nil when not injected (e.g. in Previews).
    @Environment(\.panelSizeReporter) private var panelSizeReporter

    /// Whether a sheet is currently active over the popover.
    ///
    /// Driven exclusively by the 100ms poll task reading NSWindow.sheets.
    /// ❌ NEVER set this directly from onChange or any path other than the poll task
    ///    (except the isTransientHide-guarded clear on full close).
    @State private var isSheetActive = false

    /// The NSWindow hosting this view hierarchy.
    ///
    /// Populated asynchronously by WindowReader via DispatchQueue.main.async.
    /// Will be nil for at least one runloop after the view first appears.
    /// The poll task guard handles this gracefully — do not split the guard.
    @State private var hostWindow: NSWindow?

    /// Structured task driving the 100ms sheet-detection poll loop.
    ///
    /// Started on onAppear and on each panel open. Stopped on close/disappear.
    /// Always call stopPolling() before startPolling() to avoid duplicate tasks.
    /// Named "sheetPoll" for Instruments visibility (RG6).
    ///
    /// Typed as `Task<Void, any Error>` because the body contains `try await Task.sleep`,
    /// which requires a throwing context. `Task(name:operation:)` infers `Failure == any Error`
    /// when the closure throws; using `Never` here would be a type mismatch.
    @State private var pollTask: Task<Void, any Error>?

    /// Tracks panel open/close state and the transient-hide flag.
    ///
    /// isTransientHide is set by hidePanel() before isOpen = false to let
    /// onChange and the poll task know NOT to clear isSheetActive.
    @Environment(PanelVisibilityState.self) private var panelVisibilityState: PanelVisibilityState

    /// Creates a `PanelContainerView` wrapping the given content.
    /// - Parameters:
    ///   - content: The child view to wrap inside the dim-overlay container.
    ///   - onSizeChange: Legacy per-instance callback. Defaults to no-op.
    ///     The active size path is `panelSizeReporter` from the environment.
    init(content: Content, onSizeChange: @escaping (CGSize) -> Void = { _ in }) {
        self.content = content
        self.onSizeChange = onSizeChange
    }

    /// Calls both the legacy per-instance callback and the environment reporter.
    /// Called from the background(GeometryReader) on appear and on size change.
    private func reportSize(_ size: CGSize) {
        onSizeChange(size)
        panelSizeReporter?(size)
    }

    /// Root view: stacks `content` (wrapped in a size-reporting GeometryReader),
    /// the zero-size `WindowReader`, and the optional dim overlay.
    var body: some View {
        ZStack {
            content
                // SIZE REPORTING — active path.
                // GeometryReader is inside the AnyView boundary so it measures
                // PanelMainView's typed, .fixedSize()-constrained intrinsic size.
                // Using .background (not a wrapping GeometryReader) so the
                // GeometryReader never influences content’s own layout proposal.
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { reportSize(geo.size) }
                            .onChange(of: geo.size) { _, newSize in reportSize(newSize) }
                    }
                )
            // WindowReader captures the hosting NSWindow asynchronously.
            // Zero-size so it doesn't affect layout.
            WindowReader(window: $hostWindow)
                .frame(width: 0, height: 0)
            if isSheetActive {
                // Semi-transparent overlay that blocks interaction with the
                // popover content while a sheet is presented in front of it.
                // NSPopover does not dim its own content during sheet presentation
                // the way a normal NSWindow does, so we do it manually.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    // Must hit-test true — without this, taps pass through to the
                    // content behind the sheet, which is confusing and buggy.
                    .allowsHitTesting(true)
                    .transition(.opacity)
            }
        }
        // Animate overlay appearance/disappearance.
        .animation(.easeInOut(duration: 0.15), value: isSheetActive)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open {
                panelVisibilityState.isTransientHide = false
                startPolling()
            } else {
                stopPolling()
                if !panelVisibilityState.isTransientHide {
                    isSheetActive = false
                }
            }
        }
    }

    // MARK: - Sheet detection

    @MainActor private func startPolling() {
        stopPolling()
        pollTask = Task(name: "sheetPoll") { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                guard panelVisibilityState.isOpen,
                      let window = hostWindow,
                      window.isVisible
                else {
                    if !panelVisibilityState.isTransientHide, isSheetActive {
                        isSheetActive = false
                    }
                    continue
                }
                let hasVisibleSheet = window.sheets.contains { $0.isVisible }
                if hasVisibleSheet != isSheetActive { isSheetActive = hasVisibleSheet }
            }
        }
    }

    @MainActor private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

// MARK: - WindowReader

/// Captures the NSWindow that hosts this SwiftUI view hierarchy.
///
/// Uses a zero-size NSView to access its `.window` property. The window is
/// delivered asynchronously via DispatchQueue.main.async because NSView.window
/// is nil during the synchronous makeNSView call (the view hasn't been added
/// to a window yet at that point).
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context _: Context) {
        guard nsView.window != window else { return }
        DispatchQueue.main.async { window = nsView.window }
    }
}
