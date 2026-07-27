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
//   - Apply SwiftUI-reported content sizes via the GeometryReader wrapper
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
//   PopoverController.swift          — stored properties, init, setup, deinit
//   PopoverController+Open.swift     — toggle/open/close, positioning, highlight
//   PopoverController+ContentSize.swift — applyContentSize (three-path sizing)
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
    /// `internal` (default) so extension files can access it.
    let overlayGate: MBKOverlayGate
    /// SF Symbol name for the status-bar icon.
    private let symbolName: String
    /// Minimum allowed popover content width.
    let minWidth: CGFloat
    /// Maximum allowed popover content width.
    let maxWidth: CGFloat
    /// Maximum allowed popover content height.
    let maxHeight: CGFloat
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
    /// `internal` (default) so extension files can access it.
    var hostingController: NSHostingController<AnyView>!
    /// Guards against calling `setup()` more than once.
    private var isSetUp = false
    /// Global mouse-down event monitor token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var eventMonitor: Any?
    /// Workspace app-switch observer token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?

    /// Shown-sentinel for `applyContentSize`: `true` while the popover is open,
    /// `nil` while closed. Set in `popoverWillShow`, cleared in `popoverDidClose`.
    var isShownSentinel: Bool?

    /// Opening-sentinel for `applyContentSize`: raised just before `popover.show()`
    /// in `openPopover()` and lowered at the top of the `onDidShow` Task.
    /// While true, Path 1 (not-shown) writes and Path 2 width-change reanchors
    /// are suppressed. Reset to `false` in `popoverDidClose` as a safety net.
    var isOpening = false

    /// Button center X in screen coordinates from the last visible-mode open.
    /// Used for the post-show X correction when opening while the menubar is hidden.
    /// `nil` until first visible-mode open.
    var lastKnownAnchorX: CGFloat?

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    /// `internal` (default) so extension files can access it.
    var onWillCloseFired = false

    /// Chrome width delta (window frame width − content width) for hidden-mode sizing.
    /// Snapshotted once in `popoverWillShow` per session. `nil` outside a session.
    var hiddenChromeW: CGFloat?
    /// Chrome height delta (window frame height − content height) for hidden-mode sizing.
    /// Snapshotted once in `popoverWillShow` per session. `nil` outside a session.
    var hiddenChromeH: CGFloat?
    /// Button center X in screen coordinates for the hidden-mode session.
    /// Snapshotted once in `popoverWillShow` per session. `nil` outside a session.
    var hiddenButtonMidX: CGFloat?
    /// Window top edge (`frame.maxY`) snapshotted once in `popoverWillShow` per session.
    /// Used in Path 3 to pin the top of the popover window at a fixed Y regardless of
    /// height changes: `origin.y = hiddenWindowY - windowHeight`.
    /// Snapshotting `maxY` (not `origin.y`) is critical — the window is small at
    /// snapshot time and grows later; anchoring to the top edge keeps the popover
    /// visually pinned just below the status bar across all height values.
    /// `nil` outside a hidden-mode session.
    var hiddenWindowY: CGFloat?

    // MARK: - Init

    /// Creates the controller with a root SwiftUI view and shared overlay gate.
    /// - Parameters:
    ///   - rootView: The root view displayed inside the popover.
    ///   - overlayGate: Shared gate; blocks dismiss while a sheet or picker is live.
    ///   - symbolName: SF Symbol name for the status-bar icon. Defaults to `"menubar.rectangle"`.
    ///   - minWidth: Minimum popover content width (default 200).
    ///   - maxWidth: Maximum popover content width (default 600).
    ///   - maxHeight: Maximum popover content height (default 600).
    public init<Content: View>(
        rootView: Content,
        overlayGate: MBKOverlayGate,
        symbolName: String = "menubar.rectangle",
        minWidth: CGFloat = 200,
        maxWidth: CGFloat = 600,
        maxHeight: CGFloat = 600
    ) {
        self.overlayGate = overlayGate
        self.symbolName = symbolName
        self.minWidth = minWidth
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.rootView = AnyView(rootView)
    }

    // MARK: - Setup

    /// Wires the status item, popover, and observers.
    ///
    /// **Must be called from `applicationDidFinishLaunching`** before any user
    /// interaction is possible. A `precondition` guards against calling it more than once.
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
        hostingController.rootView = wrapped(rootView)
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

    // See deinit TEARDOWN in the file header for thread-safety rationale.
    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
