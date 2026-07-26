// AnchoredSheet.swift
// MenuBarKit

import AppKit
import SwiftUI

// MARK: - Anchor task

@MainActor
func mbkWaitAndAnchorSheetWindow(
    popoverWindow: NSWindow,
    overlayGate: MBKOverlayGate,
    label: String
) -> MBKSheetAnchorTask {
    mbkLog("AnchoredSheet[\(label)]", "mbkWaitAndAnchorSheetWindow called — pw=#\(popoverWindow.windowNumber)")
    let task = MBKSheetAnchorTask(popoverWindow: popoverWindow, overlayGate: overlayGate, label: label)
    task.start()
    return task
}

@MainActor
final class MBKSheetAnchorTask {
    private let popoverWindow: NSWindow
    private let overlayGate: MBKOverlayGate
    private let label: String
    private var cancelled = false

    init(popoverWindow: NSWindow, overlayGate: MBKOverlayGate, label: String) {
        mbkLog("AnchoredSheet[\(label)]", "MBKSheetAnchorTask.init pw=#\(popoverWindow.windowNumber)")
        self.popoverWindow = popoverWindow
        self.overlayGate = overlayGate
        self.label = label
    }

    func start() {
        mbkLog("AnchoredSheet[\(label)]", "start — hop1 Task queued")
        let capturedLabel = label
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else {
                mbkLog("AnchoredSheet[\(capturedLabel)]", "hop1 — cancelled/deallocated")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "hop1 complete — queuing hop2")
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.cancelled else {
                    mbkLog("AnchoredSheet[\(capturedLabel)]", "hop2 — cancelled/deallocated")
                    return
                }
                // NOTE: `cancelled` is an @MainActor-isolated property read here
                // inside a DispatchQueue.main.async closure. This is safe at runtime
                // because GCD main queue == main thread == MainActor executor, but the
                // Swift type system does not verify this statically. Under Swift 6
                // strict concurrency this pattern may require `@MainActor` annotation
                // on the closure. The TOCTOU window between the guard check and
                // addChildWindow is acknowledged — cancellation is best-effort once
                // this hop is already executing.
                //
                // WHY THE TOCTOU RACE IS SAFE (no crash, bounded side effect):
                //   If cancel() fires after the guard passes, addChildWindow runs
                //   on a sheet window that SwiftUI is in the process of tearing down.
                //   addChildWindow(_:ordered:) on an already-closing or already-parented
                //   window is documented as a no-op on macOS — it does not crash and
                //   does not double-add the window.
                //   HOWEVER: the window may remain in pw.childWindows momentarily,
                //   causing hasSheetChildWindow = true on the very next outside-click
                //   event. That routes the event monitor to forceClose() instead of
                //   performClose(), so onWillClose fires with wasForced: true on a
                //   session that was actually a normal close. Host code that branches
                //   on wasForced must treat it as advisory rather than authoritative
                //   — documented in the README under Known Limitations.
                let pw = self.popoverWindow
                let allWindows = NSApp.windows
                mbkLog("AnchoredSheet[\(self.label)]", "hop2 — polling \(allWindows.count) windows")
                for w in allWindows where w !== pw {
                    let title = w.title.isEmpty ? "<empty>" : w.title
                    mbkLog("AnchoredSheet[\(self.label)]",
                           "  candidate #\(w.windowNumber) styleMask=\(w.styleMask.rawValue) isKey=\(w.isKeyWindow) borderless=\(w.styleMask == .borderless) inSheets=\(pw.sheets.contains(w)) title=\(title)")
                }
                guard let sheetWindow = allWindows.first(where: {
                    $0 !== pw &&
                    $0.styleMask.contains(.borderless) &&
                    $0.isKeyWindow
                }) else {
                    mbkLog("AnchoredSheet[\(self.label)]", "hop2 — no matching window found (borderless+isKey)")
                    return
                }
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow — #\(sheetWindow.windowNumber)")
                pw.addChildWindow(sheetWindow, ordered: .above)
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow done")
            }
        }
    }

    func cancel() {
        mbkLog("AnchoredSheet[\(label)]", "cancel called — cancelled was \(cancelled)")
        cancelled = true
    }

    deinit {
        // mbkLog is @MainActor-isolated and cannot be called from deinit.
        // print is used directly here — custom mbkLogHandler installations
        // will NOT receive this message.
#if DEBUG
        print("[MBK:AnchoredSheet[\(label)]] deinit")
#endif
    }
}

// MARK: - View extension

public extension View {
    /// Presents an anchored sheet and manages the overlay gate for its lifetime.
    ///
    /// `MBKOverlayGate` is resolved from the SwiftUI environment — inject it at
    /// the root view via `.environment(overlayGate)` before using this modifier.
    ///
    /// - Warning: Requires `MBKOverlayGate` to be present in the SwiftUI environment.
    ///   If not injected, SwiftUI will raise a fatal error at runtime.
    func mbkSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetModifier(isPresented: isPresented, sheetContent: content))
    }

    /// Presents an item-driven anchored sheet and manages the overlay gate for its lifetime.
    ///
    /// `MBKOverlayGate` is resolved from the SwiftUI environment — inject it at
    /// the root view via `.environment(overlayGate)` before using this modifier.
    ///
    /// - Warning: Requires `MBKOverlayGate` to be present in the SwiftUI environment.
    ///   If not injected, SwiftUI will raise a fatal error at runtime.
    func mbkSheet<Item: Identifiable & Equatable, SheetContent: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> SheetContent
    ) -> some View {
        modifier(MBKAnchoredSheetItemModifier(item: item, sheetContent: content))
    }
}

// MARK: - isPresented variant

// Internal: consumers route through the public .mbkSheet(isPresented:content:)
// View extension above. Exposing the modifier struct directly would allow
// instantiation without the @Environment(MBKOverlayGate.self) dependency
// being satisfied, which causes a SwiftUI fatal error at runtime.
struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let sheetContent: () -> SheetContent
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    init(
        isPresented: Binding<Bool>,
        sheetContent: @escaping () -> SheetContent
    ) {
        self._isPresented = isPresented
        self.sheetContent = sheetContent
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            // NOTE: SwiftUI's .sheet(isPresented:) writes the binding to false on
            // ANY dismiss path — including Escape key and system-level dismiss —
            // so this onChange fires and cleans up the gate and anchor task
            // correctly regardless of how the sheet was dismissed. There is no
            // separate code path needed for system dismissal.
            .onChange(of: isPresented) { oldValue, newValue in
                mbkLog("AnchoredSheet[isPresented]", "onChange \(oldValue)→\(newValue) windows=\(NSApp.windows.count) currentGate=\(overlayGate.hasActiveOverlay)")
                overlayGate.hasActiveOverlay = newValue
                if newValue {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[isPresented]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[isPresented]", "onChange — popoverWindow #\(popoverWindow.windowNumber), gate=true, starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "isPresented"
                    )
                } else {
                    mbkLog("AnchoredSheet[isPresented]", "onChange false — cancelling anchorTask=\(anchorTask != nil)")
                    anchorTask?.cancel()
                    anchorTask = nil
                    mbkLog("AnchoredSheet[isPresented]", "onChange false — gate=false done")
                }
            }
    }
}

// MARK: - item variant

// Internal: consumers route through the public .mbkSheet(item:content:)
// View extension above. Same @Environment fatal-error rationale as above.
struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    @Binding var item: Item?
    let sheetContent: (Item) -> SheetContent
    @Environment(MBKOverlayGate.self) private var overlayGate
    @State private var anchorTask: MBKSheetAnchorTask?

    init(
        item: Binding<Item?>,
        sheetContent: @escaping (Item) -> SheetContent
    ) {
        self._item = item
        self.sheetContent = sheetContent
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            // NOTE: SwiftUI's .sheet(item:) nils the binding on ANY dismiss path
            // — including Escape key and system-level dismiss — so this onChange
            // fires and cleans up the gate and anchor task correctly in all cases.
            // There is no separate code path needed for system dismissal.
            .onChange(of: item) { _, newValue in
                let isPresented = newValue != nil
                mbkLog("AnchoredSheet[item]", "onChange isPresented=\(isPresented) windows=\(NSApp.windows.count) currentGate=\(overlayGate.hasActiveOverlay)")
                overlayGate.hasActiveOverlay = isPresented
                if isPresented {
                    guard let popoverWindow = NSApp.windows.first(where: {
                        $0.styleMask.contains(.nonactivatingPanel)
                    }) else {
                        mbkLog("AnchoredSheet[item]", "onChange — no nonactivatingPanel, aborting")
                        return
                    }
                    mbkLog("AnchoredSheet[item]", "onChange — popoverWindow #\(popoverWindow.windowNumber), gate=true, starting task")
                    anchorTask = mbkWaitAndAnchorSheetWindow(
                        popoverWindow: popoverWindow,
                        overlayGate: overlayGate,
                        label: "item"
                    )
                } else {
                    mbkLog("AnchoredSheet[item]", "onChange false — cancelling anchorTask=\(anchorTask != nil)")
                    anchorTask?.cancel()
                    anchorTask = nil
                    mbkLog("AnchoredSheet[item]", "onChange false — gate=false done")
                }
            }
    }
}
