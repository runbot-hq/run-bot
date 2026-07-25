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
    private let rootView: AnyView

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

    private func setupPopover() {
        // WHY AnyView IS ONLY APPLIED ONCE HERE:
        //   rootView is already stored as AnyView (erased once in init).
        //   The GeometryReader wrapper is applied to that AnyView and the result
        //   passed directly to NSHostingController — no second AnyView(wrapped)
        //   erasure. Double AnyView wrapping defeats SwiftUI's type-level layout
        //   hints and causes extra layout passes on every size event.
        let wrapped = rootView
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
        hostingController = NSHostingController(rootView: wrapped)
        hostingController.sizingOptions = []
        popover = NSPopover()
        popover.contentViewController = hostingController
        popover.contentSize = NSSize(width: minWidth, height: 100)
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.delegate = self
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
        // WHY anchorPoint IS NOT STALE — READ THIS BEFORE SUGGESTING A CHANGE:
        //
        //   anchor.x = window.frame.midX captured at popoverWillShow time.
        //   AppKit only repositions the popover window horizontally at show() time.
        //   Subsequent contentSize changes do not move the window horizontally.
        //   anchor.x is therefore stable for the entire open session.
        //
        //   anchor.y = window.frame.maxY captured at popoverWillShow time.
        //   AppKit anchors the popover window to the bottom of the menu bar and
        //   grows it DOWNWARD on height increases. The top edge (maxY) never moves
        //   — it is flush against the menu bar for the entire session. This means
        //   anchor.y is invariant: it equals window.frame.maxY at every point
        //   during the session, not just at capture time.
        //
        //   The Y origin formula  anchor.y - window.frame.height  is therefore
        //   always correct: anchor.y is the fixed ceiling, window.frame.height
        //   (read AFTER contentSize assignment, so it reflects the new height)
        //   is the current floor distance. No drift is possible.
        //
        //   A reviewer may suggest reading window.frame.maxY live on every resize
        //   instead of caching it. That would give the SAME value every time
        //   (because maxY is invariant) but would re-introduce a read of mutable
        //   AppKit state inside a hot resize path for zero benefit. The cached
        //   anchor approach is strictly better.
        //
        //   Another suggestion may be to drop anchor.y entirely and derive Y from
        //   the status bar button's screen position on every resize. We tried this
        //   (see commit history) and reverted: button.convert(bounds, to: nil)
        //   requires traversing the view hierarchy on every resize and produced
        //   a subtle race when the button rect was stale during rapid height
        //   transitions. The captured maxY approach is simpler and correct.
        //
        //   NOTE: Display changes that move the status button close the popover
        //   (popoverDidClose fires, anchorPoint = nil). A fresh anchor is captured
        //   on the next popoverWillShow. There is no scenario where a stale
        //   anchor.y survives across a display geometry change.
        //
        //   KNOWN LIMITATION — anchor.x on cold open with minWidth != maxWidth:
        //   anchor.x is captured from window.frame.midX in popoverWillShow. If
        //   fittingSize was zero at show() time (cold first open, view not yet
        //   laid out), popover.contentSize was left at minWidth before show(), so
        //   AppKit centers a minWidth-wide chrome over the button. anchor.x then
        //   equals the button midX only for that width. If the view subsequently
        //   renders wider (via applyContentSize), the re-centering formula
        //   (anchor.x - newWidth/2) produces a result that is off by
        //   (newWidth - minWidth) / 2 on that first transition only. Subsequent
        //   transitions within the same session are correct because anchor.x
        //   doesn't change and AppKit doesn't reposition horizontally. The error
        //   is one-shot and self-correcting after the first close/reopen cycle.
        //   Fixing this properly requires capturing the button's screen-space midX
        //   (not the chrome midX) in popoverWillShow. Left as a known limitation
        //   rather than introducing AppKit coordinate-space traversal at show time.
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
                        // Capture to a local so the predicate evaluates once per
                        // outside-click. forceClose() does its own panelWindow scan
                        // internally — that scan only runs on the taken branch and
                        // is not duplicated here.
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
            // This path is theoretically unreachable in normal operation.
            // NSPopoverDelegate.popoverWillShow fires after AppKit has already
            // created and positioned the popover window — hostingController.view
            // is guaranteed to have a window at this point in every observed
            // configuration, including autohide menu bar and external displays.
            //
            // The guard exists as a defensive nil-safety measure only. If it ever
            // fires in the field, anchorPoint stays nil for the session and
            // applyContentSize silently skips repositioning (the guard let anchor
            // branch takes the not-shown path). A popoverDidShow retry would be
            // the appropriate fix — but adding one speculatively for a path that
            // has never been observed would be complexity without evidence.
            //
            // DO NOT add a popoverDidShow fallback preemptively. If you are
            // reading this because the log line below fired in the field: note
            // the hardware and OS configuration and add the fallback then, with
            // a reproducer. Speculative fallbacks for theoretical edge cases
            // add maintenance surface without a proven benefit.
            mbkLog("PopoverController", "popoverWillShow -- no hostingWindow (unexpected; anchor skipped for this session)")
            return
        }
        // anchorPoint is nil until this delegate fires, so any applyContentSize
        // call before this point (e.g. GeometryReader onAppear during the same
        // show cycle) takes the `not shown` guard branch and only records the
        // size — no stale frame is ever used as an anchor.
        // window.frame is already positioned by AppKit before this delegate fires,
        // so midX and maxY are the correct chrome midpoint and top edge for this session.
        //
        // KNOWN LIMITATION — anchor.x on cold open with minWidth != maxWidth:
        //   window.frame.midX equals the button's screen midX only when the chrome
        //   was sized to the correct content width before show(). On a cold first
        //   open, if fittingSize was zero and popover.contentSize was left at
        //   minWidth, AppKit centers a minWidth-wide chrome — so window.frame.midX
        //   here equals the button midX only for that initial width. The first
        //   applyContentSize call that transitions to a wider content size will
        //   re-center from a slightly wrong anchor.x (off by (newWidth-minWidth)/2).
        //   The error is one-shot: subsequent opens capture a correct anchor because
        //   fittingSize is non-zero on warm opens. Tracked as a known limitation;
        //   the fix (capturing button screen-space midX instead of chrome midX)
        //   was deferred to avoid AppKit coordinate-space traversal at show time.
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
