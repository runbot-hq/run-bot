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
    let overlayGate: MBKOverlayGate
    private let symbolName: String
    let minWidth: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    var rootView: AnyView

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) var eventMonitor: Any?
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?

    /// Shown-sentinel: `true` while popover is open, `nil` while closed.
    var isShownSentinel: Bool?

    /// Opening-sentinel: raised just before `popover.show()`, lowered in `onDidShow` Task.
    var isOpening = false

    /// Closing-sentinel: raised in `fireOnWillClose()`, lowered in `popoverDidClose`.
    var isClosing = false

    /// Button center X from last visible-mode open. `nil` until first visible open.
    var lastKnownAnchorX: CGFloat?

    /// Prevents `onWillClose` firing more than once per cycle.
    var onWillCloseFired = false

    /// Chrome width delta snapshotted at first Path 3 call. `nil` outside a session.
    var hiddenChromeW: CGFloat?
    /// Chrome height delta snapshotted at first Path 3 call. `nil` outside a session.
    var hiddenChromeH: CGFloat?
    /// Button center X for the current hidden-mode session. `nil` outside a session.
    var hiddenButtonMidX: CGFloat?
    /// Last content width actually committed to the window via `setFrame` in hidden
    /// mode. Used by Guard 3 to detect stale departing-view GR fires that would
    /// widen the window back to main dimensions after settings has been framed.
    /// `nil` outside a hidden-mode session.
    var hiddenLastSetWidth: CGFloat?

    // MARK: - Init

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

    public func setup() {
        precondition(!isSetUp, "MBKPopoverController.setup() called more than once.")
        isSetUp = true
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()
        setupWorkspaceObserver()
        mbkLog("PopoverController", "setup complete")
    }

    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}
