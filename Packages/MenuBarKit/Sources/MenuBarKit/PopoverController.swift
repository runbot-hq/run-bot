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

    /// Called just before the popover is shown. Use this to refresh content.
    public var onWillShow: (() -> Void)?
    /// Called after the popover is shown and `NSApp.activate` has been called.
    public var onDidShow: (() -> Void)?
    /// Called when the popover is about to close.
    /// `wasForced` is `true` when closed programmatically (e.g. forceClose via sheet).
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    nonisolated(unsafe) var eventMonitor: Any?
    nonisolated(unsafe) var workspaceObserver: NSObjectProtocol?

    /// Shown-sentinel for `applyContentSize`: `true` while the popover is open,
    /// `nil` while closed. Set in `popoverWillShow`, cleared in `popoverDidClose`.
    var isShownSentinel: Bool?

    /// Opening-sentinel: raised just before `popover.show()` in `openPopover()`,
    /// lowered at the top of the `onDidShow` Task (after a runloop hop), and reset
    /// to `false` in `popoverDidClose` as a safety net.
    ///
    /// While `true`, Path 1 (not-shown) writes and Path 2 width-change reanchors
    /// in `applyContentSize` are suppressed — the `onDidShow` Task issues the
    /// authoritative WRITE+REANCHOR after the popover is fully positioned.
    ///
    /// THREAD SAFETY — no lock needed:
    /// `MBKPopoverController` is `@MainActor`. Every read and write of `isOpening`
    /// is in a `@MainActor` context: the raise in `openPopover()`, the lower in
    /// `Task { @MainActor in }`, the checks in `applyContentSize`, and the reset in
    /// `popoverDidClose`. Swift 6 strict concurrency enforces this at compile time —
    /// a cross-actor write would be a compile error, not a runtime race.
    ///
    /// RELATIONSHIP WITH popoverWillShow:
    /// `isOpening` is already `true` when `popoverWillShow` fires on first open
    /// (it is raised before `popover.show()`, and `popoverWillShow` is called
    /// synchronously inside `show()`). The chrome snapshot in `popoverWillShow` does
    /// NOT check `isOpening` — the `hiddenChromeW == nil` guard is the correct
    /// discriminator between first-open and mid-session re-anchor calls. Do NOT
    /// replace that guard with an `isOpening` check: `isOpening` can be `true`
    /// during re-anchor show() calls if the Task hop hasn't landed yet.
    var isOpening = false

    var lastKnownAnchorX: CGFloat?
    var onWillCloseFired = false

    /// Chrome width delta (window frame width − content width) for hidden-mode sizing.
    /// Snapshotted once in `popoverWillShow` against AppKit's freshly-positioned frame.
    /// `nil` outside a session (cleared in `popoverDidClose`).
    ///
    /// ALSO USED AS SESSION DISCRIMINATOR in `popoverWillShow`: `nil` means first open
    /// (snapshot runs); non-nil means re-anchor call (snapshot skipped). This is the
    /// correct sentinel — `isOpening` is NOT a reliable discriminator here because it
    /// may still be `true` during a re-anchor show() before the Task hop clears it.
    var hiddenChromeW: CGFloat?
    /// Chrome height delta (window frame height − content height) for hidden-mode sizing.
    /// Snapshotted once in `popoverWillShow`. `nil` outside a session.
    var hiddenChromeH: CGFloat?
    /// Button center X in screen coordinates for the hidden-mode session.
    /// Snapshotted once in `popoverWillShow`. `nil` outside a session.
    var hiddenButtonMidX: CGFloat?
    /// Window origin Y (bottom edge, AppKit flipped coords) snapshotted once in
    /// `popoverWillShow`. Used as a fixed constant for all Path 3 `setFrame` calls
    /// so the panel top edge stays pinned under the button for the entire session.
    ///
    /// WHY FIXED AND NOT RECOMPUTED:
    /// The panel top must stay pinned under the menubar button; only height grows
    /// downward. If Y were recomputed from `window.frame.origin.y` on each call,
    /// any delta between our last `setFrame` and AppKit's internal state (compositor
    /// lag, rounding) would accumulate across height changes, drifting the top edge.
    /// Snapshotting once against AppKit's own frame eliminates drift entirely.
    ///
    /// WHY NOT window.frame.origin.y + (window.frame.height - newH) EACH TIME:
    /// That formula is algebraically equivalent when `window.frame` is perfectly
    /// consistent with our last write, but fragile: any compositor lag between
    /// `setFrame` and the next read introduces cumulative error. `hiddenWindowY`
    /// has zero drift — it never changes after the snapshot.
    ///
    /// `nil` outside a hidden-mode session (cleared in `popoverDidClose`).
    var hiddenWindowY: CGFloat?

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

    // MARK: - Root view replacement

    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Status item image

    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Status item setup

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
