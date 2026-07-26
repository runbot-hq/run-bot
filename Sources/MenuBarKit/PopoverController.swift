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
    private let overlayGate: MBKOverlayGate
    /// SF Symbol name for the status-bar icon.
    private let symbolName: String
    /// Minimum allowed popover content width.
    private let minWidth: CGFloat
    /// Maximum allowed popover content width.
    private let maxWidth: CGFloat
    /// Maximum allowed popover content height.
    private let maxHeight: CGFloat
    /// The current root SwiftUI view, wrapped in `AnyView`.
    private var rootView: AnyView

    /// Called just before the popover is shown. Use this to refresh content.
    public var onWillShow: (() -> Void)?
    /// Called after the popover is shown and `NSApp.activate` has been called.
    public var onDidShow: (() -> Void)?
    /// Called when the popover is about to close.
    /// `wasForced` is `true` when closed programmatically (e.g. forceClose via sheet).
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    /// The status-bar item that owns the trigger button.
    /// Assigned in `setup()` — see IMPLICIT-UNWRAPPED OPTIONALS in the file header.
    private var statusItem: NSStatusItem!
    /// The managed `NSPopover`. Assigned in `setup()`.
    private var popover: NSPopover!
    /// Hosts the root SwiftUI view. Assigned in `setup()`.
    private var hostingController: NSHostingController<AnyView>!
    /// Guards against calling `setup()` more than once.
    private var isSetUp = false
    /// Global mouse-down event monitor token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) private var eventMonitor: Any?
    /// Workspace app-switch observer token. `nonisolated(unsafe)` — see file header.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    /// `window.frame.maxY` captured once in `popoverWillShow`.
    /// Used only as a shown-sentinel in `applyContentSize` (`anchorY != nil` means
    /// the popover is currently shown). Not read as a positional value — frame writes
    /// derive Y from `window.frame.origin.y` directly.
    /// `nil` while the popover is closed.
    private var anchorY: CGFloat?

    /// Button center X in screen coordinates from the last visible-mode open.
    /// Used for the post-show X correction when opening while the menubar is hidden.
    /// `nil` until first visible-mode open.
    private var lastKnownAnchorX: CGFloat?

    /// Prevents `onWillClose` from firing more than once per open/close cycle.
    private var onWillCloseFired = false

    /// Chrome width delta (window frame width − content width) snapshotted in
    /// hidden mode on the first `applyContentSize` call. `nil` outside a session.
    private var hiddenChromeW: CGFloat?
    /// Chrome height delta (window frame height − content height) snapshotted in
    /// hidden mode. `nil` outside a session.
    private var hiddenChromeH: CGFloat?
    /// Button center X in screen coordinates for the hidden-mode session.
    /// `nil` outside a hidden-mode session.
    private var hiddenButtonMidX: CGFloat?

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
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Status item image

    /// Replaces the status-bar button image.
    public func setStatusItemImage(_ image: NSImage) {
        statusItem?.button?.image = image
    }

    // MARK: - Auto-hide menubar guard

    /// Returns `true` when the macOS auto-hide menubar is currently hidden (slid off-screen).
    ///
    /// `screenH < 0` signals a nil screen — treated as hidden.
    /// `buttonY > screenH` means the button window has slid above the screen top.
    /// Uses `>` (not `>=`): `buttonY == screenH` is the normal flush resting position.
    private var isMenuBarHidden: Bool {
        guard let button = statusItem.button else { return false }
        let buttonScreen = button.window?.screen
        let screenH = buttonScreen.map { $0.frame.height } ?? -1
        let buttonY = button.window?.frame.maxY ?? -1
        let hidden = screenH < 0 || buttonY > screenH
        mbkLog("PopoverController", "isMenuBarHidden=\(hidden) buttonY=\(buttonY) screenH=\(screenH)")
        return hidden
    }

    /// Button center X in screen coordinates.
    /// Derived as `buttonWin.frame.minX + button.frame.midX` so it is correct
    /// in both visible and hidden mode (`statusBarWindow.frame.midX` can be
    /// stale when the menubar is hidden).
    private var buttonScreenMidX: CGFloat? {
        guard let button = statusItem.button,
              let win = button.window else { return nil }
        return win.frame.minX + button.frame.midX
    }

    // MARK: - Private setup helpers

    /// Creates and configures the `NSStatusItem` and its button.
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    /// Toggles the popover open or closed when the status-bar button is clicked.
    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    /// Shows the popover anchored to the status-bar button.
    /// Handles pre-show `contentSize` seeding, `onWillShow`/`onDidShow` callbacks,
    /// and post-show X correction for the hidden-menubar case.
    private func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let menuBarHidden = isMenuBarHidden

        if !menuBarHidden, let anchorX = buttonScreenMidX {
            lastKnownAnchorX = anchorX
            mbkLog("PopoverController", "openPopover -- lastKnownAnchorX updated to \(anchorX)")
        }

        // Pre-show fittingSize write — seeds contentSize before show().
        // GUARDED: skip when menubar hidden — writing against off-screen button
        // causes AppKit to place the window at a bad X on open.
        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            if menuBarHidden {
                mbkLog("PopoverController", "openPopover -- menubar hidden, SKIP pre-show contentSize write (\(fitting.width),\(fitting.height))")
            } else {
                popover.contentSize = clamp(fitting)
                mbkLog("PopoverController", "openPopover -- pre-show contentSize written (\(clamp(fitting).width),\(clamp(fitting).height))")
            }
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")

        // Post-show reposition when menubar is hidden.
        // AppKit anchors the window using the button's stale off-screen position — bad X.
        // Override immediately with lastKnownAnchorX before the user sees it.
        if menuBarHidden,
           let liveAnchorX = lastKnownAnchorX,
           let window = hostingController.view.window {
            let correctedOrigin = NSPoint(
                x: liveAnchorX - window.frame.width / 2,
                y: window.frame.origin.y
            )
            window.setFrameOrigin(correctedOrigin)
            mbkLog("PopoverController",
                   "openPopover -- menubar hidden, post-show REPOSITION liveAnchorX=\(liveAnchorX) w=\(window.frame.width) origin=\(correctedOrigin)")
        } else if menuBarHidden {
            mbkLog("PopoverController", "openPopover -- menubar hidden but no lastKnownAnchorX yet, cannot reposition")
        }

        startEventMonitor()

        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    /// The `NSWindow` with `.nonactivatingPanel` style mask, if any.
    /// This is the floating panel window that backs the popover.
    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    /// `true` when the panel window has at least one child window (i.e. a sheet is attached).
    private var hasSheetChildWindow: Bool {
        !(panelWindow?.childWindows ?? []).isEmpty
    }

    /// Fires `onWillClose` exactly once per session, guarded by `onWillCloseFired`.
    private func fireOnWillClose(wasForced: Bool) {
        guard !onWillCloseFired else {
            mbkLog("PopoverController", "onWillClose already fired, skipping")
            return
        }
        onWillCloseFired = true
        mbkLog("PopoverController", "calling onWillClose wasForced=\(wasForced)")
        onWillClose?(wasForced)
        mbkLog("PopoverController", "onWillClose fired")
    }

    /// Closes all child windows of the panel and calls `popover.performClose`.
    /// Used when an outside click arrives while a non-file-picker sheet is active.
    ///
    /// NOTE: `hasFilePickerOverlay` is intentionally NOT cleared here.
    /// The event monitor only reaches `forceClose()` when `hasFilePickerOverlay` is
    /// false — the `if hasFilePicker` branch fires first and returns early.
    /// This path is therefore structurally unreachable while `hasFilePickerOverlay`
    /// is true. `popoverDidClose` is the authoritative reset point for all gate
    /// flags and always fires after `performClose()`.
    private func forceClose() {
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose -- closing child #\(child.windowNumber)")
                pw.removeChildWindow(child)
                child.close()
            }
        } else {
            mbkLog("PopoverController", "forceClose -- no panelWindow found")
        }
        mbkLog("PopoverController", "forceClose -- calling performClose")
        popover.performClose(nil)
    }

    /// Returns a 1pt-wide rect centered on `button.bounds.midX`, used as the
    /// `positioningRect` for `NSPopover.show`.
    /// Returns `nil` if `button.bounds` are degenerate (zero width or height).
    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    /// Sets the status-bar button's highlighted state.
    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    /// Creates and configures the `NSPopover` with the hosted SwiftUI root view.
    private func setupPopover() {
        hostingController = NSHostingController(rootView: wrapped(rootView))
        // MUST be []. Leaving this at the macOS default (.preferredContentSize)
        // makes AppKit auto-write contentSize from the SwiftUI view's live
        // intrinsic size on every layout pass — a second, competing write path
        // that races our own applyContentSize() call.
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Wraps `view` in a `GeometryReader` background that calls `applyContentSize`
    /// on every SwiftUI layout pass and on first appear.
    /// This is the sole mechanism by which SwiftUI reports its preferred size.
    private func wrapped(_ view: AnyView) -> AnyView {
        AnyView(view
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.size) { [weak self] _, newSize in
                            self?.applyContentSize(newSize)
                        }
                        .onAppear { [weak self] in
                            self?.applyContentSize(geo.size)
                        }
                }
            )
        )
    }

    /// Clamps `size` to `[minWidth, maxWidth] × [0, maxHeight]`.
    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    // MARK: - applyContentSize

    /// Applies a SwiftUI-reported preferred size to the popover or its backing window.
    ///
    /// Three paths: (1) not shown — write `contentSize` so it opens at the right size;
    /// (2) shown, menubar visible — write `contentSize`, re-anchor via `show()` on width
    /// change so AppKit re-derives the arrow position atomically; (3) shown, menubar
    /// hidden — `NSPopover.contentSize` is ignored by AppKit, so drive `window.setFrame`
    /// directly using snapshotted chrome deltas and `buttonMidX`.
    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }

        guard popover.isShown,
              let window = hostingController.view.window,
              anchorY != nil else {    // anchorY != nil is the shown-sentinel; its value is not used here
            // Path 1: not shown.
            //
            // GUARDED: skip when menubar is hidden. Post-close SwiftUI size
            // callbacks while hidden poison contentSize — AppKit uses the
            // stale value to anchor the next open against the off-screen button.
            if isMenuBarHidden {
                mbkLog("PopoverController",
                       "applyContentSize -- not shown, menubar hidden, SKIP WRITE (\(clamped.width),\(clamped.height))")
                return
            }
            popover.contentSize = clamped
            mbkLog("PopoverController",
                   "applyContentSize -- not shown, WRITE (\(clamped.width),\(clamped.height))")
            return
        }

        let oldWidth = popover.contentSize.width
        let widthChanged = abs(clamped.width - oldWidth) > 1

        if isMenuBarHidden {
            // Path 3: hidden mode — NSPopover ignores setContentSize here.
            //
            // Snapshot chrome deltas and buttonMidX once per hidden session so
            // every frame write re-centers correctly regardless of which view
            // is active or how many times width changes.
            if hiddenChromeW == nil,
               let button = statusItem.button,
               let buttonWin = button.window {
                hiddenChromeW = window.frame.width - popover.contentSize.width
                hiddenChromeH = window.frame.height - popover.contentSize.height
                hiddenButtonMidX = buttonWin.frame.minX + button.frame.midX
                mbkLog("PopoverController",
                       "applyContentSize -- hidden snapshot chromeW=\(hiddenChromeW!) chromeH=\(hiddenChromeH!) buttonMidX=\(hiddenButtonMidX!)")
            }
            guard let chromeW = hiddenChromeW,
                  let chromeH = hiddenChromeH,
                  let btnMidX = hiddenButtonMidX else {
                mbkLog("PopoverController",
                       "applyContentSize -- menubar hidden, no chrome snapshot yet, SKIP (\(clamped.width),\(clamped.height))")
                return
            }
            let newW = clamped.width + chromeW
            let newH = clamped.height + chromeH
            // ❌ DO NOT use window.frame.origin.x as a fixed left edge here —
            // it was computed for a specific width and is wrong for any other width.
            // Always derive originX from btnMidX so main and settings (which have
            // different widths) both land centred under the status item.
            let newX = btnMidX - newW / 2  // re-centre on the status item for every write
            // Anchor from current bottom edge upward — self-contained, no anchorY needed.
            let newY = window.frame.origin.y + (window.frame.height - newH)
            let newFrame = NSRect(x: newX, y: newY, width: newW, height: newH)
            window.setFrame(newFrame, display: true)
            mbkLog("PopoverController",
                   "applyContentSize -- menubar hidden, DIRECT FRAME (\(clamped.width),\(clamped.height)) btnMidX=\(btnMidX) frame=\(newFrame)")
        } else {
            // Path 2: menubar visible — write contentSize then re-anchor via show()
            // on width change so AppKit re-derives arrow position atomically.
            popover.contentSize = clamped
            if widthChanged {
                guard let button = statusItem.button,
                      let rect = positioningRect(for: button) else {
                    mbkLog("PopoverController",
                           "applyContentSize -- WRITE only, button unavailable for re-anchor (\(clamped.width),\(clamped.height))")
                    return
                }
                if let anchorX = buttonScreenMidX { lastKnownAnchorX = anchorX }
                popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE+REANCHOR via show() (\(clamped.width),\(clamped.height))")
            } else {
                mbkLog("PopoverController",
                       "applyContentSize -- WRITE only, height-only change (\(clamped.width),\(clamped.height))")
            }
        }
    }

    // MARK: - Workspace observer

    /// Registers for `NSWorkspace.didActivateApplicationNotification` and closes
    /// the popover when another app is foregrounded (unless an overlay is active).
    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                guard let self, self.popover.isShown else { return }
                guard activated != NSRunningApplication.current else {
                    mbkLog("PopoverController", "workspace observer -- self-activation, ignoring")
                    return
                }
                guard !overlayGate.hasActiveOverlay else {
                    mbkLog("PopoverController", "workspace observer -- overlay active, keeping popover open")
                    return
                }
                mbkLog("PopoverController", "workspace observer -- other app active, closing")
                self.popover.performClose(nil)
            }
        }
    }

    // MARK: - Event monitor

    /// Installs a global `NSEvent` monitor for left/right mouse-down events.
    /// Closes or force-closes the popover depending on overlay state.
    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController",
                       "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
                if hasOverlay {
                    if hasFilePicker {
                        mbkLog("PopoverController", "event monitor -- file picker active, ignoring outside click")
                    } else {
                        let hasSheet = self.hasSheetChildWindow
                        mbkLog("PopoverController", "event monitor -- hasSheet=\(hasSheet)")
                        if hasSheet {
                            mbkLog("PopoverController", "event monitor -- sheet overlay, force-closing")
                            self.forceClose()
                        } else {
                            mbkLog("PopoverController", "event monitor -- picker/alert overlay, ignoring outside click")
                        }
                    }
                } else {
                    mbkLog("PopoverController", "event monitor -- no overlay, performClose")
                    self.popover.performClose(nil)
                }
            }
        }
        mbkLog("PopoverController", "event monitor started")
    }

    /// Removes the global mouse-down event monitor installed by `startEventMonitor()`.
    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
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

// MARK: - NSPopoverDelegate

/// `NSPopoverDelegate` conformance — show/close lifecycle and dismiss gating.
extension MBKPopoverController: NSPopoverDelegate {
    /// Highlights the status-bar button and sets `anchorY` as the shown-sentinel for
    /// `applyContentSize`. The value itself is not used for frame positioning.
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (anchorY skipped)")
            return
        }
        anchorY = window.frame.maxY
        mbkLog("PopoverController",
               "popoverWillShow -- anchorY=\(anchorY!) win=\(window.frame) #\(window.windowNumber)")
    }

    /// Blocks the popover from closing while any overlay (sheet or file picker) is active.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    /// Fires `onWillClose`, dehighlights the button, stops the event monitor,
    /// and resets all per-session state so the next open starts clean.
    public func popoverDidClose(_ notification: Notification) {
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        // Reset all per-session state so the next open starts clean.
        // NOTE: this is the authoritative reset point for ALL gate flags, including
        // hasFilePickerOverlay. forceClose() only clears hasActiveOverlay because
        // it is structurally unreachable while hasFilePickerOverlay is true —
        // the event monitor's hasFilePicker branch returns early before forceClose.
        // Both flags are always cleared here regardless of which close path fired.
        anchorY = nil
        hiddenChromeW = nil
        hiddenChromeH = nil
        hiddenButtonMidX = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "popoverDidClose -- overlay gate reset")
    }
}
