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
// WHY THE ASYNC DISPATCH:
//   At the point onChange fires, SwiftUI has set the binding but hasn't yet
//   created the NSWindow for the sheet. The inner DispatchQueue.main.async
//   defers until the next run-loop turn by which point the window exists.
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
//   MIGRATION NOTE: isKeyWindow can transiently match other borderless windows
//   (e.g. NSOpenPanel during dismiss, OS animations). This is acceptable here
//   because anchorSheetWindow() only runs when isPresented flips to true —
//   a moment when no other borderless window should be key. Revalidate on
//   major OS updates.

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
                // Update the dismiss gate synchronously — before the window
                // lookup so popoverShouldClose sees the flag immediately.
                appState.hasActiveOverlay = newValue
                if newValue {
                    // SwiftUI has flipped the binding; defer to next run-loop
                    // turn so the sheet NSWindow actually exists by the time
                    // we go looking for it.
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            log("AnchoredSheet", "no nonactivatingPanel window found")
            return
        }
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
