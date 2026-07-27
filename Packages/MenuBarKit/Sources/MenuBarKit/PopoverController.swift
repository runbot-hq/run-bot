// PopoverController.swift
// MenuBarKit
//
// Owns the full NSPopover + NSStatusItem lifecycle for a macOS menu-bar app.
// Zero knowledge of the host app's views or state — all app-specific behaviour
// is injected via closures at configuration time.
//
// RESPONSIBILITIES:
//   - Create and show/hide the NSPopover
//   - Manage the NSStatusItem button highlight
//   - Install/remove the outside-click NSEvent monitor
//   - Install/remove the NSWorkspace app-switch observer
//   - Implement popoverShouldClose via the MBKOverlayGate
//   - Reset the overlay gate in popoverDidClose (safety net)
//   - Pin popover window top edge via didMove/didResize notifications (pinPopoverWindow)
//
// STAY-OPEN-WHILE-SHEET-ACTIVE — deliberate trade-off:
//   When a sheet (or file picker) is live, MBKPopoverController keeps the
//   popover open on app-switch and outside-click instead of hiding it.
//   popoverShouldClose returns false (via overlayGate.hasActiveOverlay), and
//   the workspace observer skips performClose while any overlay is active.
//
// DISMISS GATE CONTRACT:
//   popoverShouldClose reads overlayGate.hasActiveOverlay. MBKAnchoredSheet
//   and mbkOpenFilePicker manage the gate automatically — the host app never
//   needs to touch it directly.
//
// OUTSIDE-CLICK MONITOR:
//   Started when the popover opens, stopped when it closes. Never leaks a
//   persistent global listener.
//
// WORKSPACE OBSERVER — why queue: nil + Task { @MainActor } (not queue: .main):
//   queue: nil delivers on the poster's thread; Task { @MainActor } is the
//   Swift 6-correct hop to the main actor — compiler-enforced, not asserted.
//
// IMPLICIT-UNWRAPPED OPTIONALS (statusItem, popover, hostingController):
//   Assigned in setup(), not init(). Safe because setup() is called from
//   applicationDidFinishLaunching before any user interaction is possible.
//   ❌ Do NOT replace with optionals without also replacing setup() with
//   init-time wiring.
//
// nonisolated(unsafe) — eventMonitor AND workspaceObserver:
//   Both hold opaque tokens from AppKit APIs that are not Sendable.
//   Every live read/write is @MainActor-isolated. Safe under the singleton
//   lifetime assumption — see deinit note below.
//
// deinit TEARDOWN:
//   NSEvent.removeMonitor is thread-safe. NSWorkspace notificationCenter
//   removeObserver is safe here because MBKPopoverController outlives all
//   concurrent work under normal singleton usage.
//
// CROSS-FILE EXTENSION ACCESS (PopoverController+*.swift):
//   Members accessed by extensions in other files are marked `internal` (the
//   Swift default — no explicit keyword). `fileprivate` is file-scoped and
//   would NOT grant access across files. `internal` is still invisible to
//   module consumers.
//
// FILE ORGANISATION:
//   PopoverController.swift             — stored properties, init, setup, deinit
//   PopoverController+Open.swift        — toggle/open/close, positioning, highlight, window pin
//   PopoverController+Observers.swift   — workspace observer, event monitor
//   PopoverController+Delegate.swift    — NSPopoverDelegate conformance

import AppKit
import SwiftUI

/// Manages the full `NSPopover` and `NSStatusItem` lifecycle for a macOS menu-bar app.
///
/// Inject a root SwiftUI view and an `MBKOverlayGate` at init time, then call `setup()`
/// from `applicationDidFinishLaunching`. All app-specific behaviour is provided via
/// the `onWillShow`, `onDidShow`, and `onWillClose` closures.
@MainActor
public final class MBKPopoverController: NSObject, MBKPopoverControllerProtocol {

    // MARK: - Configuration

    /// Overlay gate — read in `popoverShouldClose` and reset in `popoverDidClose`.
    let overlayGate: MBKOverlayGate
    /// SF Symbol name for the status-bar icon.
    private let symbolName: String
    /// The current root SwiftUI view, wrapped in `AnyView`.
    var rootView: AnyView

    /// Called just before the popover is shown. Use this to refresh content.
    public var onWillShow: (() -> Void)?
    /// Called after the popover is shown and `NSApp.activate` has been called.
    public var onDidShow: (() -> Void)?
    /// Called when the popover is about to close.
    /// `wasForced` is `true` when closed programmatically (e.g. forceClose via sheet).
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    /// The status-bar item that owns the trigger button.
    /// Assigned in `setup()` — see IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    var statusItem: NSStatusItem!
    /// The managed `NSPopover`. Assigned in `setup()`.
    var popover: NSPopover!
    /// Hosts the root SwiftUI view. Assigned in `setup()`.
    var hostingController: NSHostingController<AnyView>!
    /// Guards against calling `setup()` more than once.
    private var isSetUp = false
    /// Global mouse-down event monitor token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var eventMonitor: Any?
    /// Workspace app-switch observer token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?

    /// Button center X in screen coordinates from the last open.
    /// Used in hidden-menubar mode to position the arrow anchor panel before show().
    /// `nil` until first open.
    ///
    /// X-staleness note: when the auto-hide menubar slides off-screen, only the
    /// button window's Y coordinate becomes stale (the bar slides vertically).
    /// The horizontal position (frame.minX) remains valid and is safe to read
    /// even while the bar is hidden. This is why `lastKnownAnchorX` is updated
    /// unconditionally from `buttonScreenMidX` on every open — the value is
    /// always accurate. The guard on `lastKnownAnchorX != nil` in the hidden
    /// path exists only to protect the first-ever open before any X has been seen.
    var lastKnownAnchorX: CGFloat?

    /// The popover window's `frame.maxY` (top edge) snapshotted in `pinPopoverWindow()`
    /// after `popoverDidShow` settles. As content grows the window height increases;
    /// `handlePopoverWindowMoved` recomputes `origin.y = pinnedWindowMaxY - height`
    /// so the top edge stays fixed just below the menu bar regardless of size changes.
    /// Cleared in `unpinPopoverWindow()` on close.
    var pinnedWindowMaxY: CGFloat?

    /// `true` when the current open session used the hidden-menubar ghost-panel path.
    /// Set in `openPopover()` and read in `handlePopoverWindowMoved()` to gate the
    /// X/Y correction — in visible-menubar mode AppKit owns window position and the
    /// pin must not interfere with its own repositioning logic.
    /// Reset in `unpinPopoverWindow()` on close.
    var isPinnedForHiddenMode: Bool = false

    /// `NSWindow.didMoveNotification` observer token. Managed by
    /// `pinPopoverWindow()` / `unpinPopoverWindow()`.
    var windowMoveObserver: Any?

    /// `NSWindow.didResizeNotification` observer token. Managed by
    /// `pinPopoverWindow()` / `unpinPopoverWindow()`.
    var windowResizeObserver: Any?

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    var onWillCloseFired = false

    /// Invisible 20×1pt `NSPanel` used as `positioningView` for `NSPopover.show`
    /// in hidden-menubar mode. Positioned at `lastKnownAnchorX - 10` in screen
    /// coordinates so AppKit bakes the arrow at the correct center X at show() time.
    ///
    /// ❌ Do NOT close this panel before `popoverDidClose`. AppKit holds a weak
    /// reference to the positioningView's window; closing it earlier causes AppKit
    /// to lose the anchor and jump the popover origin to (0, y) on the next
    /// preferredContentSize-driven resize event. `unpinPopoverWindow()` is the
    /// correct and only close site.
    var arrowAnchorPanel: NSPanel?

    // MARK: - Init

    /// Creates the controller with a root SwiftUI view and shared overlay gate.
    /// - Parameters:
    ///   - rootView: The root view displayed inside the popover.
    ///   - overlayGate: Shared gate; blocks dismiss while a sheet or picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle"
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.rootView = AnyView(rootView)
    }

    // MARK: - Setup

    /// Wires the status item, popover, and observers.
    ///
    /// **Must be called from `applicationDidFinishLaunching`** before any user
    /// interaction is possible. Assigns the three IUO properties (`statusItem`,
    /// `popover`, `hostingController`). Any call to `togglePopover()` before
    /// `setup()` completes will crash on the `!` unwrap — intentional; surfaces
    /// ordering errors immediately.
    ///
    /// ❌ NEVER call `setup()` more than once. A `precondition` guards this at runtime.
    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    // MARK: - Root view replacement

    /// Replaces the popover's root view at runtime.
    /// Safe to call before or after `setup()`.
    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = rootView
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Status item image

    /// Replaces the status-bar button image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Status item setup

    /// Creates and configures the `NSStatusItem` and its button.
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    // MARK: - Deallocation

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
