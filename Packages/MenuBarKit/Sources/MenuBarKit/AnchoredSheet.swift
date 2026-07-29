// AnchoredSheet.swift
// MenuBarKit

import AppKit
import SwiftUI

// MARK: - Anchor task

/// Spawns a two-hop async task that waits for the sheet's `NSWindow` to appear
/// in `NSApp.windows`, then attaches it as a child of the popover window so
/// outside-click detection works correctly.
///
/// Returns the running `MBKSheetAnchorTask` so the caller can cancel it if the
/// sheet is dismissed before the window is found.
@MainActor
func mbkWaitAndAnchorSheetWindow(
    popoverWindow: NSWindow,
    label: String
) -> MBKSheetAnchorTask {
    mbkLog("AnchoredSheet[\(label)]", "mbkWaitAndAnchorSheetWindow called — pw=#\(popoverWindow.windowNumber)")
    let task = MBKSheetAnchorTask(popoverWindow: popoverWindow, label: label)
    task.start()
    return task
}

/// Manages the two-hop window-search-and-anchor sequence for a SwiftUI sheet.
///
/// `start()` queues a `Task { @MainActor }` hop followed by a
/// `DispatchQueue.main.async` hop. The double-hop gives AppKit time to add the
/// sheet's `NSWindow` to `NSApp.windows` before we search for it.
/// Call `cancel()` if the sheet is dismissed before the anchor completes.
@MainActor
final class MBKSheetAnchorTask {
    /// The popover's backing window; the sheet window will be added as its child.
    private let popoverWindow: NSWindow
    /// Debug label used in log output to identify which sheet this task belongs to.
    private let label: String
    /// Set to `true` by `cancel()`. Checked at the start of each hop.
    private var cancelled = false

    /// Creates the task. Does not start the async work — call `start()` explicitly.
    init(popoverWindow: NSWindow, label: String) {
        mbkLog("AnchoredSheet[\(label)]", "MBKSheetAnchorTask.init pw=#\(popoverWindow.windowNumber)")
        self.popoverWindow = popoverWindow
        self.label = label
    }

    /// Begins the two-hop async search for the sheet window.
    func start() {
        mbkLog("AnchoredSheet[\(label)]", "start — hop1 Task queued")
        let capturedLabel = label
        Task { @MainActor [weak self] in
            guard let self, !self.cancelled else {
                mbkLog("AnchoredSheet[\(capturedLabel)]", "hop1 — cancelled/deallocated")
                return
            }
            mbkLog("AnchoredSheet[\(self.label)]", "hop1 complete — queuing hop2")
            // TODO: GCD hop in MBKSheetAnchorTask.start() — see issue #21 for Swift 6 migration path
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else {
                    mbkLog("AnchoredSheet[\(capturedLabel)]", "hop2 — cancelled/deallocated")
                    return
                }
                // @MainActor isolation is statically verified.
                // The TOCTOU window between the guard check and
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
                //   on wasForced must treat it as advisory rather than authoritative.
                let pw = self.popoverWindow
                let allWindows = NSApp.windows
                mbkLog("AnchoredSheet[\(self.label)]", "hop2 — polling \(allWindows.count) windows")
                for w in allWindows where w !== pw {
                    let title = w.title.isEmpty ? "<empty>" : w.title
                    mbkLog(
                        "AnchoredSheet[\(self.label)]",
                        "  candidate #\(w.windowNumber) styleMask=\(w.styleMask.rawValue)" +
                        " isKey=\(w.isKeyWindow) borderless=\(w.styleMask == .borderless)" +
                        " inSheets=\(pw.sheets.contains(w)) title=\(title)"
                    )
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
                pw.contentView?.layoutSubtreeIfNeeded()
                pw.addChildWindow(sheetWindow, ordered: .above)
                // NSGlassEffectView is the direct panel.contentView — no chrome wrapper.
                // Direct contentView survives addChildWindow() without corner regression.
                pw.invalidateShadow()
                mbkLog("AnchoredSheet[\(self.label)]", "addChildWindow done")
            }
        }
    }

    /// Cancels the pending anchor search. Safe to call multiple times.
    /// Best-effort — has no effect if hop2 has already begun executing.
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

/// SwiftUI `View` helpers for presenting anchored sheets via `MBKAnchoredSheetModifier`.
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
/// `ViewModifier` backing `.mbkSheet(isPresented:content:)`.
/// Internal — use the `View.mbkSheet(isPresented:content:)` extension instead.
struct MBKAnchoredSheetModifier<SheetContent: View>: ViewModifier {
    /// Binding that controls whether the sheet is currently presented.
    @Binding var isPresented: Bool
    /// The sheet content factory.
    let sheetContent: () -> SheetContent
    /// The gate that blocks popover dismiss while the sheet is live.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// The running anchor task, held so it can be cancelled on dismiss.
    @State private var anchorTask: MBKSheetAnchorTask?

    /// Creates the modifier.
    /// - Parameters:
    ///   - isPresented: Binding that controls presentation.
    ///   - sheetContent: Factory closure that produces the sheet's content view.
    init(
        isPresented: Binding<Bool>,
        sheetContent: @escaping () -> SheetContent
    ) {
        self._isPresented = isPresented
        self.sheetContent = sheetContent
    }

    /// Applies the sheet and gate-management logic to `content`.
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented, content: sheetContent)
            // NOTE: SwiftUI's .sheet(isPresented:) writes the binding to false on
            // ANY dismiss path — including Escape key and system-level dismiss —
            // so this onChange fires and cleans up the gate and anchor task
            // correctly regardless of how the sheet was dismissed.
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
/// `ViewModifier` backing `.mbkSheet(item:content:)`.
/// Internal — use the `View.mbkSheet(item:content:)` extension instead.
struct MBKAnchoredSheetItemModifier<Item: Identifiable & Equatable, SheetContent: View>: ViewModifier {
    /// Binding to the item that drives sheet presentation; `nil` when dismissed.
    @Binding var item: Item?
    /// The sheet content factory, called with the current non-nil item.
    let sheetContent: (Item) -> SheetContent
    /// The gate that blocks popover dismiss while the sheet is live.
    @Environment(MBKOverlayGate.self) private var overlayGate
    /// The running anchor task, held so it can be cancelled on dismiss.
    @State private var anchorTask: MBKSheetAnchorTask?

    /// Creates the modifier.
    /// - Parameters:
    ///   - item: Binding to the item that drives presentation.
    ///   - sheetContent: Factory closure that produces the sheet's content view.
    init(
        item: Binding<Item?>,
        sheetContent: @escaping (Item) -> SheetContent
    ) {
        self._item = item
        self.sheetContent = sheetContent
    }

    /// Applies the item-driven sheet and gate-management logic to `content`.
    func body(content: Content) -> some View {
        content
            .sheet(item: $item, content: sheetContent)
            // NOTE: SwiftUI's .sheet(item:) nils the binding on ANY dismiss path
            // — including Escape key and system-level dismiss — so this onChange
            // fires and cleans up the gate and anchor task correctly in all cases.
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
