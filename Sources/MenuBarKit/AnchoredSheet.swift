// AnchoredSheet.swift
// MenuBarKit
//
// PROBLEM:
//   SwiftUI's .sheet() creates a plain borderless NSWindow with no parent.
//   macOS treats it as a peer of the popover window, so:
//     - The sheet hides when the user clicks away from the app.
//     - The popover can be closed by an outside-click while the sheet is open.
//
// SOLUTION:
//   After SwiftUI presents the sheet, walk NSApp.windows to find the new
//   borderless+key window and call addChildWindow(_:ordered:) on the popover
//   window. Once it is a child it follows the popover and stays visible when
//   the popover window loses focus.
//
//   In addition, the modifier sets overlayGate.hasActiveOverlay = true when
//   the sheet opens and false when it closes. MBKPopoverController reads this
//   flag in popoverShouldClose to block dismiss.
//
// WHY TWO ASYNC HOPS:
//   Hop 1 — Task { @MainActor } in onChange:
//     Actor-isolation crossing only. Gets us onto MainActor so we can call
//     @MainActor-isolated code. Does NOT guarantee the NSWindow exists yet.
//
//   Hop 2 — DispatchQueue.main.async inside anchorSheetWindow():
//     Drains one more run-loop turn, by which point SwiftUI has created the
//     sheet NSWindow and NSApp.windows contains it.
//
// SHEET WINDOW DISCRIMINATOR — why .borderless && isKeyWindow:
//   The sheet window is matched by: not the popover window, borderless styleMask,
//   and isKeyWindow at the moment Hop 2 fires.
//
//   An earlier version used `contentViewController is NSHostingController<AnyView>`
//   as a stronger discriminator, but SwiftUI's internal sheet window does NOT use
//   that exact generic specialisation — the check never matched in practice and
//   was reverted. Do not re-attempt this without first verifying the concrete
//   NSHostingController generic type SwiftUI uses for sheet windows on the
//   target OS version.
//
//   isKeyWindow is the most reliable signal available at the moment the sheet
//   is presented — SwiftUI makes the sheet window key immediately on creation.
//   Known fragility: other transient borderless windows (OS animations, fast
//   NSOpenPanel re-open) may be key at the same moment. Both races are
//   eliminated by the TARGET IMPLEMENTATION below.
//
// TARGET IMPLEMENTATION (deferred — see notes):
//   Replace Hop 2 with NSWindow.didBecomeKeyNotification observation:
//
//   @MainActor
//   private func waitForSheetWindow(excluding popoverWindow: NSWindow) async -> NSWindow? {
//       await withCheckedContinuation { continuation in
//           var observer: NSObjectProtocol?
//           observer = NotificationCenter.default.addObserver(
//               forName: NSWindow.didBecomeKeyNotification,
//               object: nil, queue: .main
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
//   Deferred because withCheckedContinuation leaks if the sheet is dismissed
//   before its NSWindow ever becomes key. Needs a cancellation path before
//   this enters production. Implement with the migration PR.
//
// MIGRATION NOTE:
//   The DispatchQueue.main.async mixes GCD with Swift concurrency and bypasses
//   actor checking. It must be replaced with the NSWindow.didBecomeKeyNotification
//   approach above before this code enters the main app.

import AppKit
import SwiftUI

public extension View {
    /// Presents a sheet anchored as a child of the popover window so it
    /// survives outside-clicks and stays visible when the popover loses focus.
    ///
    /// Also manages `overlayGate.hasActiveOverlay` automatically — the host
    /// view does not need to touch the gate directly.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        overlayGate: MBKOverlayGate,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(
            isPresented: isPresented,
            overlayGate: overlayGate,
            sheetContent: content
        ))
    }
}

public struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding public var isPresented: Bool
    public let overlayGate: MBKOverlayGate
    public let sheetContent: () -> SheetContent

    public func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            .onChange(of: isPresented) { _, newValue in
                // Set the dismiss gate synchronously — before the window
                // lookup so popoverShouldClose sees the flag immediately.
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    // Hop 1: actor-isolation crossing only.
                    Task { @MainActor in anchorSheetWindow() }
                }
            }
    }

    @MainActor
    private func anchorSheetWindow() {
        guard let popoverWindow = NSApp.windows.first(where: {
            $0.styleMask.contains(.nonactivatingPanel)
        }) else {
            mbkLog("AnchoredSheet", "no nonactivatingPanel window found — sheet will not be anchored")
            return
        }
        // Hop 2: drain one run-loop turn so the sheet NSWindow exists.
        // ⚠️ SPIKE ONLY — replace with NSWindow.didBecomeKeyNotification.
        // See SHEET WINDOW DISCRIMINATOR note in the file header before
        // attempting to strengthen the predicate below.
        DispatchQueue.main.async {
            if let sheetWindow = NSApp.windows.first(where: {
                $0 !== popoverWindow
                    && $0.styleMask.contains(.borderless)
                    && $0.isKeyWindow
            }) {
                mbkLog("AnchoredSheet", "addChildWindow")
                popoverWindow.addChildWindow(sheetWindow, ordered: .above)
            } else {
                mbkLog("AnchoredSheet", "no borderless+key window found")
            }
        }
    }
}
