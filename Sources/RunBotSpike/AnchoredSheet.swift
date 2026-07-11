// AnchoredSheet.swift
// RunBotSpike - spike/swiftui-nav-sheet
//
// PROBLEM:
//   SwiftUI's .sheet() creates a plain borderless NSWindow behind the scenes.
//   That window has no parent, so macOS treats it as a peer of the popover window.
//   Consequences:
//     - The sheet hides when the user clicks away from the app because it isn't
//       considered part of the popover.
//     - The popover can be closed by an outside-click even while the sheet is open,
//       which tears the whole UI down underneath the user.
//
// SOLUTION:
//   After SwiftUI presents the sheet (i.e. after isPresented flips true), walk
//   NSApp.windows to find the new borderless+key window and call
//   addChildWindow(_:ordered:) on the popover window.
//   Once it is a child:
//     - It follows the popover on screen.
//     - It stays visible when the popover window loses focus.
//
//   In addition, the modifier sets appState.hasActiveOverlay = true when the
//   sheet opens and false when it closes. AppDelegate reads this flag in
//   popoverShouldClose to block dismiss. This keeps dismiss-gate logic out of
//   individual views — they own only their local @State isPresented binding.
//
// WHY hasActiveOverlay INSTEAD OF win.childWindows:
//   Relying on win.childWindows in popoverShouldClose requires the window
//   hierarchy to always be consistent with SwiftUI state, which has proven
//   fragile (timing of addChildWindow, OS version differences). A single
//   @Observable flag on AppState is the authoritative source of truth —
//   it is set exactly when isPresented flips true and cleared when it flips
//   false, with no window-walk needed.
//
// WHY TWO ASYNC HOPS (not one):
//   Two distinct problems require two distinct deferrals:
//
//   Hop 1 — Task { @MainActor } in onChange:
//     onChange fires in a non-isolated SwiftUI closure. The Task hop is purely
//     an actor-isolation crossing (P4) — it gets us onto the MainActor executor
//     so we can safely call @MainActor-isolated code. It does NOT guarantee the
//     NSWindow exists yet; it only guarantees we're on the right actor.
//
//   Hop 2 — DispatchQueue.main.async inside anchorSheetWindow():
//     Even after the actor hop, SwiftUI hasn't necessarily created the NSWindow
//     for the sheet yet. The inner DispatchQueue.main.async drains one more
//     run-loop turn, by which point the window exists and NSApp.windows contains
//     it. This is the deferral that actually makes the window lookup work.
//
//   They solve different problems. Collapsing to one hop would either lose actor
//   isolation (if only DispatchQueue) or find no window (if only Task { @MainActor }).
//
// TARGET IMPLEMENTATION (deferred — do not use current Hop 2 in production):
//   The correct Swift 6.2-native replacement for the DispatchQueue.main.async
//   hop is to observe the event we actually care about: the sheet NSWindow
//   becoming key. This is fully deterministic, eliminates the isKeyWindow race
//   conditions, and keeps full actor isolation (P4):
//
//   @MainActor
//   private func anchorSheetWindow() async {
//       guard let popoverWindow = ... else { return }
//       let sheetWindow = await waitForSheetWindow(excluding: popoverWindow)
//       guard let sheetWindow else { return }
//       popoverWindow.addChildWindow(sheetWindow, ordered: .above)
//   }
//
//   @MainActor
//   private func waitForSheetWindow(excluding popoverWindow: NSWindow) async -> NSWindow? {
//       await withCheckedContinuation { continuation in
//           var observer: NSObjectProtocol?
//           observer = NotificationCenter.default.addObserver(
//               forName: NSWindow.didBecomeKeyNotification,
//               object: nil,
//               queue: .main
//           ) { notification in
//               guard
//                   let window = notification.object as? NSWindow,
//                   window !== popoverWindow,
//                   window.styleMask.contains(.borderless)
//               else { return }
//               NotificationCenter.default.removeObserver(observer!)
//               continuation.resume(returning: window)
//           }
//       }
//   }
//
//   WHY DEFERRED:
//     withCheckedContinuation leaks if the sheet is dismissed before the
//     NSWindow ever becomes key (e.g. very fast programmatic dismiss). The
//     production implementation needs a cancellation path — either
//     withCheckedThrowingContinuation with Task cancellation support, or a
//     timeout that resumes with nil. The right cancellation design depends on
//     how the surrounding migration PR structures its Task lifetime, which
//     is not yet locked down. Implement this as part of that PR, not here.
//
// MIGRATION NOTE: The inner DispatchQueue.main.async mixes GCD with Swift
//   concurrency and bypasses actor checking (P4). It must be replaced with
//   the NSWindow.didBecomeKeyNotification approach above before this code
//   enters the main app. Do not copy the DispatchQueue pattern.
//
// WHY nonactivatingPanel AS THE ANCHOR:
//   NSPopover uses an NSPanel with .nonactivatingPanel in its styleMask as its
//   content window. That is the only reliably stable identifier for the popover
//   window — other window properties (level, title, class) vary across OS versions.
//
// WHY overlayCount IS GONE:
//   Earlier versions incremented a counter to track open overlays. That was
//   fragile (counter could desync on error paths). hasActiveOverlay on AppState
//   is set/cleared by the modifier directly — no counters needed.
//
// SHEET WINDOW DISCRIMINATOR:
//   We match the sheet window by: borderless + isKeyWindow + not the popover window.
//   isKeyWindow is the most reliable signal at the moment the sheet is presented —
//   SwiftUI makes the sheet window key immediately on creation.
//
//   Alternatives tried and rejected:
//   - NSHostingController<AnyView> type check: SwiftUI's internal sheet window does
//     not use that exact generic type, so the check never matched.
//   - frame.intersects(popoverWindow.frame): matched the wrong window on macOS 26,
//     causing addChildWindow to be called on an incompatible window, which triggered
//     an infinite recursion crash in _applyWindowLevelWithTagUpdateNeeded.
//
//   MIGRATION NOTE: isKeyWindow can transiently match other borderless windows.
//   This is mitigated in the TARGET IMPLEMENTATION above (notification fires on
//   the exact window, no walk needed). For the current spike implementation,
//   two known race windows must be validated before production migration:
//
//   1. macOS 26 compositor / Liquid Glass animation layer: introduces additional
//      transient borderless windows that may be key at the moment Hop 2 runs.
//      Test with the status-bar icon visible on macOS 26 before signing off.
//
//   2. NSOpenPanel fast re-open race: if the user opens the sheet immediately
//      after dismissing a file picker, the NSOpenPanel NSWindow may still be
//      borderless+key when Hop 2 fires. addChildWindow on an NSOpenPanel can
//      trigger the same infinite recursion crash seen with the rejected
//      frame.intersects approach.
//
//   Both races are eliminated by the TARGET IMPLEMENTATION. Treat both as
//   migration blockers for the current implementation.

import AppKit
import SwiftUI

extension View {
    func anchoredSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(NavAnchoredSheetModifier(
            isPresented: isPresented,
            sheetContent: content
        ))
    }
}

struct NavAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent
    // The modifier owns the dismiss-gate update so individual views never
    // need to touch appState for sheet lifecycle.
    @Environment(NavSheetAppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                // Set the dismiss gate synchronously — before the window lookup
                // so popoverShouldClose sees the flag immediately.
                appState.hasActiveOverlay = newValue
                if newValue {
                    // Hop 1: actor isolation crossing only (see WHY TWO ASYNC HOPS above).
                    // The run-loop deferral that makes the NSWindow exist is Hop 2,
                    // inside anchorSheetWindow() itself.
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            // The popover window is gone — this should not happen in normal flow
            // since onChange only fires while the popover is shown. If it does,
            // hasActiveOverlay is already true so the dismiss gate is correctly
            // armed. The sheet won't be anchored as a child window, but
            // popoverDidClose will reset hasActiveOverlay = false unconditionally
            // when the popover eventually closes, leaving no stale state.
            log("AnchoredSheet", "no nonactivatingPanel window found — sheet will not be anchored")
            return
        }
        // Hop 2: drain one more run-loop turn so SwiftUI's sheet NSWindow exists
        // in NSApp.windows by the time we search for it (see WHY TWO ASYNC HOPS).
        // ⚠️ SPIKE ONLY — do not copy to production. See TARGET IMPLEMENTATION
        // in the file header for the correct Swift 6.2-native replacement.
        DispatchQueue.main.async {
            // The sheet window SwiftUI just created: borderless and key,
            // but not the popover window itself.
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                log("AnchoredSheet", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                log("AnchoredSheet", "no borderless+key window found")
            }
        }
    }
}
