// PanelContainerView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - PanelContainerView
//
// Thin wrapper around the real panel content that adds a sheet-dim overlay.
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
// ❌ NEVER use GeometryReader here — it fights NSPopover's sizing.
//
// ── TRANSIENT HIDE / RESTORE ANIMATION INVARIANT ────────────────────────────────────────
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
// ── POLL TASK GUARD SPLIT (do not re-split, fixed jitter)───────────────────────
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
// ── SLEEP-FIRST LOOP ORDER (do not change) ─────────────────────────────────────
//
// The poll loop sleeps BEFORE executing the guard. hostWindow is delivered via
// DispatchQueue.main.async in WindowReader.makeNSView, so it is nil for at least
// one runloop after the view appears. Sleeping first matches the original
// Timer.scheduledTimer behaviour (first fire after 100ms, not immediately) and
// avoids an immediate guard-fail tick before hostWindow is populated.
//
// ── CANCELLATION: bare try on Task.sleep ───────────────────────────────────────
//
// Task.sleep is called with bare `try`, not `try?`. When stopPolling() cancels
// the task mid-sleep, CancellationError propagates out of the loop immediately
// without executing a spurious post-cancel tick. `try?` would swallow the error
// and allow one extra iteration before Task.isCancelled is re-checked.
//
// ────────────────────────────────────────────────────────────────────────────

/// Wraps popover content and dims it when a SwiftUI sheet is active.
struct PanelContainerView<Content: View>: View {
    /// The child view to wrap.
    let content: Content

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
    /// - Parameter content: The child view to wrap inside the dim-overlay container.
    init(content: Content) {
        self.content = content
    }

    /// Root view: stacks `content`, the zero-size `WindowReader`, and the optional dim overlay.
    var body: some View {
        ZStack {
            content
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
        // This only plays on genuine false→true (sheet opens) and true→false
        // (sheet closes) transitions. It does NOT re-play on transient hide/restore
        // because isSheetActive is kept true throughout — see invariant above.
        .animation(.easeInOut(duration: 0.15), value: isSheetActive)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
        .onChange(of: panelVisibilityState.isOpen) { _, open in
            if open {
                // Re-open after transient hide or fresh open.
                // Reset the flag so the next close is treated as a real close
                // unless hidePanel() sets it again.
                panelVisibilityState.isTransientHide = false
                startPolling()
                // ❌ Do NOT reset isSheetActive here — on transient restore the
                //    sheet window is still alive and isSheetActive is still true.
                //    Resetting it here would trigger a false→true cycle and replay
                //    the cover animation on every app-switch restore.
            } else {
                stopPolling()
                // Only clear the overlay on a genuine full close (closePanel).
                // On transient hide, hidePanel() sets isTransientHide = true
                // before flipping isOpen, so we skip the clear here.
                // Clearing during a transient hide would cause the animation to
                // replay on re-entry even though the sheet never actually closed.
                if !panelVisibilityState.isTransientHide {
                    isSheetActive = false
                }
            }
        }
    }

    // MARK: - Sheet detection
    //
    // NSWindow.sheets is the authoritative source for whether a sheet is
    // currently attached. We poll it because NSPopoverWindowFrame does not
    // post NSWindow.willBeginSheetNotification / didEndSheetNotification, and
    // there is no KVO-observable property without subclassing NSWindow.
    //
    // Task interval 100ms: fast enough to feel instant, cheap enough at 10Hz.

    /// Starts (or restarts) the repeating sheet-detection poll task.
    ///
    /// Always calls `stopPolling()` first to cancel any existing task.
    /// Safe to call multiple times — will not create duplicate tasks.
    /// `@MainActor` is explicit so the compiler statically verifies that `pollTask`
    /// (a `@State`-backed property) is always mutated on the main actor.
    @MainActor private func startPolling() {
        stopPolling()
// Sleep-FIRST — see "SLEEP-FIRST LOOP ORDER" comment at the top of this file.
        // Single atomic guard — do NOT split. See "POLL TASK GUARD SPLIT" comment above.
        // bare `try` — see "CANCELLATION" comment at the top of this file.
        pollTask = Task(name: "sheetPoll") { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(100))
                // Single atomic guard — do NOT split into two separate guards.
                // See "POLL TASK GUARD SPLIT" comment at the top of this file for why.
                //
                // This guard fails when:
                //   a) isOpen is false (panel is closing or closed)
                //   b) hostWindow is nil (not yet delivered by WindowReader async)
                //   c) window.isVisible is false (transient hide — window ordered out)
                //
                // In all these cases we fall into the else branch to decide whether
                // to clear isSheetActive. We only clear it on a genuine close, not
                // during a transient hide where the sheet window is still alive.
                guard panelVisibilityState.isOpen,
                      let window = hostWindow,
                      window.isVisible
                else {
                    // isTransientHide = true means hidePanel() caused this guard
                    // to fail (window ordered out but sheet still attached).
                    // Keep isSheetActive as-is so restore has nothing to re-animate.
                    //
                    // isTransientHide = false means closePanel() or the window
                    // genuinely disappeared — safe to clear.
                    if !panelVisibilityState.isTransientHide, isSheetActive {
                        isSheetActive = false
                    }
                    continue
                }

                // Window is visible and panel is open — ground truth read.
                let hasVisibleSheet = window.sheets.contains { $0.isVisible }
                // Guard against redundant SwiftUI state updates (no-op if unchanged).
                if hasVisibleSheet != isSheetActive { isSheetActive = hasVisibleSheet }
            }
        }
    }

    /// Cancels and nils the poll task.
    /// `@MainActor` matches `startPolling()` — both mutate `pollTask`.
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
///
/// The poll task in PanelContainerView handles the nil-window case gracefully
/// via its atomic guard — do not assume hostWindow is non-nil on first tick.
private struct WindowReader: NSViewRepresentable {
    /// Updated with the NSWindow that hosts this view hierarchy.
    @Binding var window: NSWindow?

    /// Creates the underlying NSView and reports its window asynchronously.
    func makeNSView(context _: Context) -> NSView {
        let view = NSView(frame: .zero)
        // Async because view.window is nil synchronously at make time.
        DispatchQueue.main.async { window = view.window }
        return view
    }

    /// Updates the window binding when the view's window changes.
    /// Guards against redundant binding updates — nsView.window is stable after
    /// the first assignment and re-dispatching on every SwiftUI update would
    /// trigger unnecessary state invalidations in PanelContainerView.
    /// Pointer equality is safe here because NSPopover reuses the same NSWindow
    /// object across transient hide/restore cycles.
    func updateNSView(_ nsView: NSView, context _: Context) {
        guard nsView.window != window else { return }
        DispatchQueue.main.async { window = nsView.window }
    }
}
