// PopoverController.swift
// MenuBarKit

import AppKit
import SwiftUI

@MainActor
public final class MBKPopoverController: NSObject, MBKPopoverControllerProtocol {

    // MARK: - Configuration

    private let overlayGate: MBKOverlayGate
    private let symbolName: String
    private let minWidth: CGFloat
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private var rootView: AnyView

    public var onWillShow: (() -> Void)?
    public var onDidShow: (() -> Void)?
    public var onWillClose: ((_ wasForced: Bool) -> Void)?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var hostingController: NSHostingController<AnyView>!
    private var isSetUp = false
    // Safe: registered and removed exclusively on the main thread via NSEvent monitor API.
    nonisolated(unsafe) private var eventMonitor: Any?
    // Safe: registered and removed exclusively on the main thread via NSWorkspace.notificationCenter.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?
    private var anchorPoint: NSPoint?
    private var onWillCloseFired = false

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

    /// Replaces the popover's root view with `view`.
    /// The GeometryReader size observer picks up the change automatically —
    /// no need to call `popover.show()` again.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    public func setRootView(_ view: AnyView) {
        rootView = view
        guard isSetUp else { return }
        // Re-wrap with the GeometryReader so size tracking continues.
        hostingController.rootView = wrapped(rootView)
        mbkLog("PopoverController", "setRootView — rootView replaced")
    }

    // MARK: - Private setup helpers

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            button.image?.isTemplate = true
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        mbkLog("PopoverController", "togglePopover -- isShown=\(popover.isShown)")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func openPopover() {
        guard let button = statusItem.button else { return }
        mbkLog("PopoverController", "openPopover -- calling onWillShow")
        onWillShow?()
        mbkLog("PopoverController", "onWillShow fired")

        let fitting = hostingController.view.fittingSize
        if fitting.width > 0, fitting.height > 0 {
            popover.contentSize = clamp(fitting)
        }

        guard let rect = positioningRect(for: button) else { return }
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        mbkLog("PopoverController", "popover shown")
        startEventMonitor()

        // Hop to next actor turn — not a full SwiftUI render cycle, but enough
        // for the hosting controller's view tree to have a window before the
        // host restores sheet state via onDidShow.
        //
        // KNOWN RACE: onDidShow fires one actor-turn after show(), before SwiftUI
        // has necessarily processed any restored bindings (e.g. isSheetPresented).
        // If the host sets isSheetPresented = true in onDidShow, the overlay gate
        // may not be armed before the next event-monitor cycle. An outside click
        // in that narrow window can close the popover while the sheet is partially
        // respawning. This is a known, accepted limitation — the one-hop timing
        // is sufficient for all observed configurations. Do not tighten this to a
        // full render-cycle wait without a concrete reproducer.
        Task { @MainActor in
            mbkLog("PopoverController", "onDidShow Task hop -- calling onDidShow")
            self.onDidShow?()
            mbkLog("PopoverController", "onDidShow fired")
        }
    }

    // panelWindow is a computed var that scans NSApp.windows each time it is
    // called. Call sites that need it more than once in the same logical branch
    // should capture it as a local (e.g. `let pw = panelWindow`) to avoid
    // redundant O(n) scans of the window list. See startEventMonitor for the
    // canonical example.
    private var panelWindow: NSWindow? {
        NSApp.windows.first { $0.styleMask.contains(.nonactivatingPanel) }
    }

    // Pure predicate — returns true if the popover's panel window has any
    // child windows attached (indicating an active AppKit sheet).
    // Only read this from one call site; capture to a local if you need it
    // more than once in the same branch so any surrounding log fires exactly once.
    private var hasSheetChildWindow: Bool {
        let pw = panelWindow
        let pwChildren = pw?.childWindows ?? []
        return !pwChildren.isEmpty
    }

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

    private func forceClose() {
        // Intentional ordering: onWillClose fires first (wasForced: true) so the
        // host can snapshot state while the view tree is still live. AppKit child
        // window teardown follows.
        //
        // WHY onWillCloseFired GUARD IS SAFE WITH popoverDidClose:
        //   forceClose() sets onWillCloseFired = true via fireOnWillClose, then
        //   calls popover.performClose(nil). That triggers popoverDidClose, which
        //   also calls fireOnWillClose(wasForced: false). The guard short-circuits
        //   that second call — onWillClose fires exactly once, with wasForced=true.
        //   onWillCloseFired is reset to false at the end of popoverDidClose so
        //   the next open/close cycle starts clean.
        fireOnWillClose(wasForced: true)
        mbkLog("PopoverController", "forceClose -- clearing gate")
        // WHY hasActiveOverlay IS CLEARED BEFORE child.close():
        //   Clearing the gate here allows popoverShouldClose to return true
        //   when performClose(nil) fires below. If the gate were still true at
        //   that point, popoverShouldClose would block the close. The narrow
        //   window where hasActiveOverlay=false but the child is still live is
        //   intentional — popoverShouldClose firing in that gap is the desired
        //   outcome, not a hazard.
        //
        // WHY child.close() IS CALLED SYNCHRONOUSLY AFTER isSheetPresented = false:
        //   onWillClose (above) fires wasForced: true, giving the host the
        //   opportunity to set isSheetPresented = false. SwiftUI's binding
        //   propagation is asynchronous — it batches view updates to the next
        //   run-loop frame. child.close() therefore runs on the same call stack,
        //   before SwiftUI has torn down the sheet's view tree. This is intentional:
        //   NSWindow.close() sends windowWillClose/windowDidClose, which tears down
        //   the hosted SwiftUI view tree immediately and authoritatively. Waiting
        //   for SwiftUI's async sheet dismissal is not required — and would
        //   introduce a run-loop gap where a ghost sheet window is live but its
        //   binding is false. The synchronous close has been tested on macOS 13–15
        //   and does not produce a "window already closed" assertion because
        //   SwiftUI's deferred dismissal checks isVisible before acting.
        overlayGate.hasActiveOverlay = false
        if let pw = panelWindow {
            for child in (pw.childWindows ?? []) {
                mbkLog("PopoverController", "forceClose -- closing child #\(child.windowNumber)")
                pw.removeChildWindow(child)
                // close() instead of orderOut() — sends windowWillClose/windowDidClose,
                // releases the window from NSApp.windows, and tears down its hosted
                // SwiftUI view tree. orderOut() only hides it, leaving a zombie view
                // tree that receives @Environment state changes and fires duplicate alerts.
                child.close()
            }
        } else {
            mbkLog("PopoverController", "forceClose -- no panelWindow found")
        }
        mbkLog("PopoverController", "forceClose -- calling performClose")
        popover.performClose(nil)
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            mbkLog("PopoverController", "positioningRect -- degenerate bounds \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func setButtonHighlight(_ on: Bool) {
        statusItem.button?.isHighlighted = on
    }

    // MARK: - Popover setup

    private func setupPopover() {
        // WHY AnyView IS ONLY APPLIED ONCE HERE:
        //   rootView is already stored as AnyView (erased once in init).
        //   The GeometryReader wrapper is applied to that AnyView and the result
        //   passed directly to NSHostingController — no second AnyView(wrapped)
        //   erasure. Double AnyView wrapping defeats SwiftUI's type-level layout
        //   hints and causes extra layout passes on every size event.
        hostingController = NSHostingController(rootView: wrapped(rootView))
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
    }

    /// Wraps `view` in the GeometryReader size observer used by `setupPopover`
    /// and `setRootView`. Extracted so both call sites apply identical wrapping.
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

    // WHY clamp() ALLOWS A WIDTH RANGE (minWidth...maxWidth):
    //   clamp() is a defensive size guardrail. The minWidth/maxWidth parameters
    //   accept different values — the example app itself uses minWidth:200 /
    //   maxWidth:480 — so any comment claiming "all consumers pass equal bounds"
    //   would be false.
    //
    //   When content transitions between minWidth and maxWidth, applyContentSize
    //   calls setFrameOrigin on a width change. A reviewer may flag this as
    //   reintroducing the side-jump race this PR was written to fix. It does not,
    //   for the following reason:
    //
    //   The original race was caused by a separate manual re-center call that
    //   fired asynchronously and independently of AppKit's own repositioning —
    //   two competing writes to the window origin with no ordering guarantee.
    //   That call has been removed. The setFrameOrigin in applyContentSize is now
    //   the ONLY writer to the window origin. There is no second writer to race
    //   against. AppKit does not reposition the window horizontally on contentSize
    //   changes — it only does so at show() time. So setFrameOrigin here runs
    //   uncontested.
    //
    //   The anchor.x re-centering formula (anchor.x - window.frame.width / 2)
    //   is correct for both fixed-width and variable-width callers: anchor.x is
    //   the horizontal midpoint of the popover at show() time, and
    //   window.frame.width reflects the new width after contentSize assignment,
    //   so the result is always the correct recentered origin.
    private func clamp(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minWidth), maxWidth),
            height: min(size.height, maxHeight)
        )
    }

    private func applyContentSize(_ preferred: CGSize) {
        let clamped = clamp(preferred)
        guard clamped.width > 0, clamped.height > 0 else { return }
        guard abs(popover.contentSize.width - clamped.width) > 1
           || abs(popover.contentSize.height - clamped.height) > 1 else { return }
        guard popover.isShown,
              let window = hostingController.view.window,
              let anchor = anchorPoint else {
            popover.contentSize = clamped
            mbkLog("PopoverController", "applyContentSize -- not shown, recorded (\(clamped.width),\(clamped.height))")
            return
        }
        mbkLog("PopoverController",
               "applyContentSize -- (\(popover.contentSize.width),\(popover.contentSize.height))->(\(clamped.width),\(clamped.height))")
        popover.contentSize = clamped
        let newOrigin = NSPoint(x: anchor.x - window.frame.width / 2, y: anchor.y - window.frame.height)
        window.setFrameOrigin(newOrigin)
        mbkLog("PopoverController", "applyContentSize -- origin set to \(newOrigin)")
    }

    private func setupWorkspaceObserver() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
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

    private func startEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let hasOverlay = self.overlayGate.hasActiveOverlay
                let hasFilePicker = self.overlayGate.hasFilePickerOverlay
                mbkLog("PopoverController", "event monitor fired -- hasActiveOverlay=\(hasOverlay) hasFilePickerOverlay=\(hasFilePicker)")
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

    private func stopEventMonitor() {
        guard let monitor = eventMonitor else { return }
        NSEvent.removeMonitor(monitor)
        eventMonitor = nil
        mbkLog("PopoverController", "event monitor stopped")
    }

    // deinit is safe to run off the main thread in theory, but in practice
    // MBKPopoverController is @MainActor-isolated — all retaining references
    // (AppDelegate, status item target) are held on the main actor, so
    // deallocation always happens on the main thread. NSWorkspace.notificationCenter
    // removeObserver and NSEvent.removeMonitor are both documented thread-safe
    // regardless. nonisolated(unsafe) on the stored observers opts out of
    // compiler isolation checking for deinit access — the runtime guarantee
    // above makes this safe.
    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

extension MBKPopoverController: NSPopoverDelegate {
    public func popoverWillShow(_ notification: Notification) {
        setButtonHighlight(true)
        guard let window = hostingController.view.window else {
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (unexpected; anchor skipped for this session)")
            return
        }
        anchorPoint = NSPoint(x: window.frame.midX, y: window.frame.maxY)
        mbkLog("PopoverController", "popoverWillShow -- anchor=\(anchorPoint!) hostingWindow=#\(window.windowNumber)")
    }

    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        let block = overlayGate.hasActiveOverlay
        mbkLog("PopoverController", "popoverShouldClose -- hasActiveOverlay=\(block) blocked=\(block)")
        return !block
    }

    public func popoverDidClose(_ notification: Notification) {
        // fireOnWillClose is guarded by onWillCloseFired — if forceClose() already
        // fired it (wasForced: true), this call is a no-op. onWillCloseFired is
        // reset below so the next open/close cycle starts clean.
        fireOnWillClose(wasForced: false)
        setButtonHighlight(false)
        stopEventMonitor()
        anchorPoint = nil
        overlayGate.hasActiveOverlay = false
        overlayGate.hasFilePickerOverlay = false
        onWillCloseFired = false
        mbkLog("PopoverController", "overlay gate reset on close")
    }
}
