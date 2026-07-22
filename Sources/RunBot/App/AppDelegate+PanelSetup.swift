// AppDelegate+PanelSetup.swift
// RunBot
import AppKit
import AppUpdater
import RunBotCore
import SwiftUI

// MARK: - AppDelegate + Panel Setup
//
// Owns NSPopover construction, KVO on preferredContentSize, and
// subscriptions that drive icon/store updates.
// Called once from applicationDidFinishLaunching via setupPanel().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupPanel() more than once.
//
// WHY NSPopover (#1017):
// NSPopover uses NSPopoverWindowFrame whose chrome is drawn by the
// window-server compositor. Rounded corners survive SwiftUI .sheet
// attachment natively — no CALayer manipulation required or desired.
//
// POPOVER BEHAVIOR: .applicationDefined (#1195)
// behavior = .applicationDefined is set at setupPanel() AND re-asserted
// immediately before every popover.show() call in openPanel(). AppKit latches
// the behavior at show-time; failing to re-assert it caused silent reversion
// to .transient between sessions (Attempt 8 root cause).
//
// OUTSIDE-CLICK / APP-SWITCH HIDE (#1195):
// Both are handled by a manual NSEvent global monitor (outsideClickMonitor)
// and an NSWorkspace observer (workspaceObserver), both installed by openPanel()
// and torn down by tearDownOpenState().
//
// SIZE / SIDE-JUMP FIX (fix/#2239):
// contentSize writes are intercepted by GuardedPopover.contentSize (below).
// The setter evaluates isMenuBarHidden via statusItemProvider — a lazy closure
// that reads self.statusItem at write-time. This is required because setupPanel()
// runs before setupStatusItem(), so statusItem is nil at construction time.
// ✅ sizingOptions = .preferredContentSize is kept — required for
//    NSHostingController to keep computing preferredContentSize.
//    Without this, preferredContentSize never changes and the KVO observer
//    never fires — popover freezes at initial size.
//    The ObjC write path from sizingOptions is intercepted by
//    GuardedPopover.contentSize setter. See fix/#2239.
// ❌ NEVER replace statusItemProvider with a stored weak var wired at setup time.
//    It will always be nil because setupStatusItem() runs after setupPanel().
// ❌ NEVER call popover.show() again on resize.
//
// isMenuBarHidden CORRECT SIGNAL (fix/#2239):
//   screenH < 0 || buttonY >= screenH
//
//   screenH < 0 means button.window.screen returned nil. This can happen when
//   the Dock slides the NSStatusItem window fully off the screen edge. Any
//   contentSize write in this state causes AppKit to re-run anchor geometry
//   against the invalid button position → side-jump to x=0.
//
//   WRONG expressions (do not use):
//     screenH > 0 && buttonY >= screenH  ← evaluates false when screen==nil
//                                           (screenH=-1, `> 0` fails, guard skipped)
//     buttonScreen != nil && buttonY >= screenH  ← same problem
//
//   Observed values:
//     Hidden (screen nil):   buttonY=-1,   screenH=-1
//     Hidden (screen alive): buttonY=982,  screenH=982
//     Visible:               buttonY=949,  screenH=982

// MARK: - GuardedPopover

/// NSPopover subclass that intercepts all `contentSize` writes and skips them
/// when the auto-hide menubar is hidden (button window off-screen).
///
/// ## Why this is needed (fix/#2239)
/// `sizingOptions = .preferredContentSize` causes AppKit to write `contentSize`
/// internally whenever SwiftUI's `preferredContentSize` changes (row expand,
/// view swap, etc.). This write path is synchronous inside the SwiftUI layout
/// pass and bypasses any guard in `resizeAndRepositionPanel()`.
///
/// By owning the setter we intercept ALL write paths — AppKit-internal AND
/// the manual path from `resizeAndRepositionPanel()` — in one place.
///
/// ## Lazy statusItemProvider
/// `setupPanel()` runs before `setupStatusItem()`, so `statusItem` is nil when
/// the popover is constructed. `statusItemProvider` is a closure evaluated at
/// write-time so it always reads the live statusItem value.
///
/// ## isMenuBarHidden signal
/// `screenH < 0 || buttonY >= screenH`
/// - screenH < 0: button.window.screen is nil — button window is off-screen.
/// - buttonY >= screenH: screen still associated but origin is at/beyond edge.
/// Either means AppKit anchor geometry is invalid; skip the contentSize write.
/// ❌ Do NOT use `screenH > 0 && buttonY >= screenH` — that evaluates false
///    when screen==nil (screenH=-1), allowing the write and causing side-jump.
final class GuardedPopover: NSPopover {

    /// Lazy provider for the current NSStatusItem.
    /// Evaluated on every contentSize write — never stored as a value.
    /// ❌ Do NOT replace with a stored weak var wired at init time — it will be nil.
    var statusItemProvider: (() -> NSStatusItem?)?

    override var contentSize: NSSize {
        get { super.contentSize }
        set {
            let button = statusItemProvider?()?.button
            let buttonWin = button?.window
            let buttonY = buttonWin?.frame.origin.y ?? -1
            let screenH = buttonWin?.screen?.frame.height ?? -1
            // fix/#2239: screenH < 0 means screen==nil (button off-screen);
            // buttonY >= screenH is the normal hidden case.
            // ❌ Do NOT use `screenH > 0 && buttonY >= screenH` — evaluates
            //    false when screen is nil, skipping the guard and causing jump.
            let isMenuBarHidden = screenH < 0 || buttonY >= screenH
            log("GuardedPopover › contentSize setter — "
                + "new=(\(newValue.width),\(newValue.height)) "
                + "current=(\(super.contentSize.width),\(super.contentSize.height)) "
                + "buttonY=\(buttonY) screenH=\(screenH) "
                + "isMenuBarHidden=\(isMenuBarHidden)")
            guard !isMenuBarHidden else {
                log("GuardedPopover › contentSize setter — SKIP: "
                    + "isMenuBarHidden=true (screenH=\(screenH) buttonY=\(buttonY)) (fix/#2239)")
                return
            }
            log("GuardedPopover › contentSize setter — WRITE (\(newValue.width),\(newValue.height))")
            super.contentSize = newValue
        }
    }
}

// MARK: - AppDelegate + NSPopoverDelegate

/// Extension responsible for NSPopover construction, KVO, and async subscriptions.
extension AppDelegate: NSPopoverDelegate {

    // MARK: Popover construction

    /// Constructs the `GuardedPopover`, wires the hosting controller, and attaches KVO.
    /// Called once from `applicationDidFinishLaunching`. ❌ NEVER call more than once.
    func setupPanel() {
        log("AppDelegate › setupPanel — begin")
        let controller = NSHostingController(rootView: mainView())
        // Required: keeps NSHostingController computing preferredContentSize.
        // Without this, preferredContentSize never changes and the KVO observer
        // never fires — popover freezes at initial size.
        // The ObjC write path from sizingOptions is intercepted by
        // GuardedPopover.contentSize setter. See fix/#2239.
        controller.sizingOptions = .preferredContentSize
        hostingController = controller

        let newPopover = GuardedPopover()
        // Wire statusItem lazily via closure — statusItem is nil here because
        // setupStatusItem() runs after setupPanel().
        // ❌ Do NOT use newPopover.statusItem = statusItem (nil at this point).
        newPopover.statusItemProvider = { [weak self] in self?.statusItem }
        newPopover.contentViewController = controller
        newPopover.contentSize = NSSize(width: 480, height: 300)
        newPopover.animates = false
        newPopover.behavior = .applicationDefined
        newPopover.delegate = self

        popover = newPopover
        log("AppDelegate › setupPanel — GuardedPopover created, wiring KVO + subscriptions")

        setupKVO(controller: controller)
        log("AppDelegate › setupPanel — complete")
    }

    // MARK: NSPopoverDelegate

    /// Allows the popover to close. Always returns `true`; AppKit calls this before
    /// any programmatic or user-driven close.
    public func popoverShouldClose(_ popover: NSPopover) -> Bool {
        #if DEBUG
        log("AppDelegate › popoverShouldClose — "
            + "behavior=\(popover.behavior.rawValue) "
            + "panelIsOpen=\(panelIsOpen) "
            + "caller=\(Thread.callStackSymbols[1])")
        #endif
        log("AppDelegate › popoverShouldClose — returning true (allowing close)")
        return true
    }

    /// Called by AppKit after the popover window closes. Tears down open state
    /// when the OS closes the popover unexpectedly (outside the normal hide/close paths).
    public func popoverDidClose(_ _: Notification) {
        #if DEBUG
        let behaviorRaw = (NSApp.delegate as? AppDelegate)?.popover?.behavior.rawValue ?? -1
        let stack = Thread.callStackSymbols.prefix(5).joined(separator: "||")
        log("AppDelegate › popoverDidClose — panelIsOpen=\(panelIsOpen) behavior=\(behaviorRaw) stack=\(stack)")
        #endif
        guard panelIsOpen else {
            log("AppDelegate › popoverDidClose — guard exit (panelIsOpen already false)")
            return
        }
        log("AppDelegate › popoverDidClose — calling tearDownOpenState (unexpected OS-driven close)")
        tearDownOpenState()
    }

    // MARK: KVO

    /// Attaches a KVO observer on `controller.preferredContentSize`.
    /// Fires `resizeAndRepositionPanel()` on the main actor whenever SwiftUI
    /// publishes a new preferred size (row expand, view swap, etc.).
    private func setupKVO(controller: NSHostingController<AnyView>) {
        log("AppDelegate › setupKVO — attaching preferredContentSize observer")
        sizeObservation = controller.observe(
            \.preferredContentSize,
            options: [.new]
        ) { [weak self] _, change in
            guard let size = change.newValue, size.height > 0 else { return }
            Task { @MainActor [weak self] in self?.resizeAndRepositionPanel() }
        }
    }
}
