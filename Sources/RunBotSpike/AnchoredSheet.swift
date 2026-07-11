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
//   NSApp.windows to find the new borderless window and call
//   addChildWindow(_:ordered:) on the popover window.
//   Once it is a child:
//     - It follows the popover on screen.
//     - It stays visible when the popover window loses focus.
//     - popoverShouldClose can detect it in win.childWindows and block dismiss
//       (see AppDelegate.swift).
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
//   fragile (counter could desync on error paths). popoverShouldClose now reads
//   win.sheets (NSOpenPanel attached as sheet) and win.childWindows (SwiftUI sheet
//   attached via addChildWindow) directly — no counters needed.
//
// SHEET WINDOW DISCRIMINATOR:
//   We match the sheet window by: borderless + visible + frame intersects the
//   popover window's frame + is not the popover window itself.
//
//   Why not NSHostingController<AnyView> type check:
//     Tried this — SwiftUI's internal sheet window does not use that exact type
//     so the check never matched and addChildWindow never fired.
//
//   Why not isKeyWindow:
//     Fragile — other borderless windows (NSOpenPanel during dismiss, OS
//     animations) can transiently become key.
//
//   Why frame intersection:
//     The sheet always appears centred over or near the popover. No other
//     borderless visible window should be overlapping the popover frame at
//     the moment the sheet is being presented.
//
//   MIGRATION NOTE: revalidate this heuristic on major OS updates. If multiple
//   borderless windows can legitimately overlap the popover simultaneously,
//   a more specific discriminator will be needed.

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

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
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
            // Find the sheet window: borderless, visible, overlaps the popover,
            // and is not the popover window itself.
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isVisible
                    && $0.frame.intersects(popoverWindow.frame)
            }) {
                log("AnchoredSheet", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                log("AnchoredSheet", "no matching sheet window found")
            }
        }
    }
}
