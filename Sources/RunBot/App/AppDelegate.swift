// AppDelegate.swift
// RunBot

import AppKit
import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - NSPopover architecture note
//
// ⚠️ NSPopover is used instead of NSPanel as of fix/#1017.
//
// WHY NSPopover instead of NSPanel:
// NSPanel with custom CAShapeLayer masking or cornerRadius+masksToBounds
// loses its rounded corners whenever a SwiftUI .sheet is presented as a
// child NSWindow. AppKit's sheet attachment path modifies the parent
// window's CALayer tree, discarding any mask or masksToBounds we set.
// NSPopover uses NSPopoverWindowFrame, a dedicated window class whose chrome
// is drawn by the window-server compositor — completely unaffected by sheet
// attachment. Rounded corners survive .sheet natively.
//
// HOW THE POPOVER WORKS:
// 1. NSPopover with animates=false, behavior=.applicationDefined.
// 2. Shown via popover.show(relativeTo: button.bounds, of: button,
//    preferredEdge: .minY) — anchors to the status bar button once on open.
//    The arrow anchor is determined by positioningRect+view at show() time
//    and is NOT moved when contentSize is updated later.
// 3. Size is driven by KVO on NSHostingController.preferredContentSize.
//    Both width AND height are updated via popover.contentSize.
//    ⚠️ Do NOT call popover.show() again on resize — that re-anchors and jumps.
//    Updating contentSize alone resizes in place with the arrow fixed.
// 4. Width is clamped to [minWidth..maxWidth] from screen bounds.
// 5. Dismiss: popover.performClose(nil) driven by the global NSEvent monitor
//    (outside clicks) and NSWorkspace app-switch notification.
//    See openPanel() for the monitor implementation.
//    See docs/graveyard.md for history of attempted alternatives.
//
// ARROW VISIBILITY (#1184):
// The NSPopover anchor arrow visibility is controlled by the `shouldHideAnchor`
// private KVC key, applied immediately before each `popover.show()` call.
// This is NOT App Store safe but RunBot is not App Store distributed.
// The preference is stored in AppPreferencesStore.showPopoverArrow (default: true).
// ⚠️ The arrow state is baked in at show() time — changing the pref takes
// effect on the NEXT open. Never call show() mid-session to apply it.
// ⚠️ The KVC call is guarded by responds(to:) so the app degrades silently
// (arrow stays visible) rather than crashing if Apple removes the key.
//
// TEXT INPUT:
// NSPopover windows are key-capable natively. NSApp.activate() is
// sufficient to allow TextFields to receive first-responder.
//
// LATERAL JUMP PREVENTION:
// Only update contentSize — never re-call popover.show() on resize.
// Updating contentSize repositions the popover body but keeps the arrow
// anchored to the original positioningRect on the status bar button.
//
// DEFERRED RESIZE IN navigate(to:) AND openPanel() — fix/#2234:
// With macOS menu bar auto-hide enabled, the status bar button's backing
// NSWindow lives in an off-screen slot managed by the Dock process. A
// synchronous contentSize write immediately after show() or a rootView swap
// causes AppKit to re-solve the arrow anchor against the off-screen button
// geometry, producing a lateral jump. The fix is to defer contentSize writes
// to the next main-actor scheduling turn via Task { @MainActor }, so AppKit
// has committed the anchor before any resize arrives.
// See issue #2234 and ARCHITECTURE.md §Preventing Side-Jump on Resize.
//
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR (HIDDEN STATE) — fix/#2239:
// When the auto-hide menubar is fully hidden, the Dock pushes the NSStatusItem
// button's NSWindow off screen: buttonWin.frame.origin.y >= screen.frame.height.
// Any contentSize write then causes AppKit to re-run full anchor geometry against
// the off-screen button, collapsing popover x-origin to 0 (side-jump).
// Fix: allow all contentSize writes unconditionally; observe popoverWindow.frame
// and snap x back to pinnedPopoverOriginX when AppKit corrupts it.
// See installWindowFrameSnapObserver(on:) and issue #2239.
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is set in openPanel()/closePanel()/hidePanel().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// See ARCHITECTURE.md §panelVisibilityState.
//
// SHEET STATE ACROSS HIDE/SHOW:
// When the user taps outside while a sheet is open, hidePanel() is called.
// Goal: re-opening the status bar icon should show settings WITH the sheet.
// - hidePanel() does NOT reset rootView. SwiftUI @State is preserved.
// - On re-open, popover.show() reattaches the same NSHostingController.
// closePanel() resets rootView so the next open starts fresh.
// ❌ NEVER add dismissSheets() to hidePanel() — it destroys sheet @State.
// ❌ NEVER reset hostingController.rootView inside hidePanel().

// MARK: - AppDelegate

// ⚠️ @MainActor isolation — see ARCHITECTURE.md §@MainActor isolation.
// ❌ NEVER remove @MainActor from this class declaration.

/// Manages AppDelegate state and behaviour.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // NOTE: Properties are `internal` (not `private`) because Swift `private`
    // does not cross file boundaries. AppDelegate+Navigation.swift requires
    // read/write access to all of them.

    // MARK: - AppState

    /// Single coordinator for all domain-level state.
    /// Replaces the scattered property bag — see issue #2040.
    let appState = AppState()

    /// The NSStatusItem anchoring the menu-bar icon and popover.
    var statusItem: NSStatusItem?
    /// The NSPopover that hosts the SwiftUI panel.
    var popover: NSPopover?
    /// The SwiftUI hosting controller embedded inside `popover`.
    var hostingController: NSHostingController<AnyView>?

    /// Gate that tracks whether a sheet or file-picker overlay is active.
    let overlayGate = MBKOverlayGate()
    /// Sheet state that must survive transient popover hides.
    let panelSheetState = PanelSheetState()
    /// Owns `panelIsOpen`, monitors, and workspace observer.
    let lifecycleCoordinator = PopoverLifecycleCoordinator()
    /// KVO token for `NSHostingController.preferredContentSize`.
    var sizeObservation: NSKeyValueObservation?

    // MARK: - fix/#2239: window frame KVO snap
    //
    // pinnedPopoverOriginX: x-origin captured after popover.show().
    // windowFrameObservation: KVO on popoverWindow.frame, fires synchronously,
    // snaps x back to pinnedPopoverOriginX when AppKit corrupts it while
    // auto-hide menubar is hidden (buttonY >= screenH).
    // Both reset in tearDownOpenState().
    // ❌ NEVER nil windowFrameObservation before tearDownOpenState().
    // See installWindowFrameSnapObserver(on:) for the observer body.

    /// X-origin of the popover window captured immediately after popover.show().
    var pinnedPopoverOriginX: CGFloat?
    /// KVO observation on the popover window's NSWindow.frame. See fix/#2239.
    var windowFrameObservation: NSKeyValueObservation?

    /// Shared observable that tracks whether the panel is open.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()
    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    var panelIsOpen: Bool { lifecycleCoordinator.panelIsOpen }
    var preservedSheetWindowHide: Bool { lifecycleCoordinator.preservedSheetWindowHide }
    /// Maximum popover content width (90% of screen).
    var maxWidth: CGFloat { min(900, statusItemScreen.visibleFrame.width * 0.9) }
    /// Maximum popover height (85% of visible screen).
    var maxHeight: CGFloat { statusItemScreen.visibleFrame.height * 0.85 }
    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Sheet guard

    /// Returns true when a SwiftUI sheet is currently presented over the popover.
    var hasActiveSheet: Bool {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return false }
        return !popoverWindow.sheets.isEmpty
    }

    // MARK: - Environment injection

    /// Wraps a SwiftUI view in the shared environment objects required by the panel.
    /// ❌ NEVER remove `panelVisibilityState` from the environment injection here.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        let suppressHidePanel: @MainActor @Sendable () -> Void = { [weak self] in
            self?.lifecycleCoordinator.suppressHidePanel()
        }
        return AnyView(view
            .environment(panelVisibilityState)
            .environment(appState)
            .environment(overlayGate)
            .environment(\.suppressHidePanel, suppressHidePanel)
        )
    }

    // MARK: - Popover resize

    /// Clamps the popover's `contentSize` to the current screen bounds.
    /// ⚠️ Never call synchronously from navigate(to:) or openPanel() — always
    /// via a deferred Task { @MainActor } to prevent side-jump. See #2234.
    /// ⚠️ fix/#2239: isMenuBarHidden guard removed. Writes go through unconditionally.
    /// Any x-origin corruption is corrected by windowFrameObservation after the fact.
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: panelIsOpen=\(panelIsOpen) popover=\(popover != nil) controller=\(hostingController != nil)")
            return
        }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: preferred.height=\(preferred.height) <= 0, skipping")
            return
        }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        let popoverWinFrame = popover.contentViewController?.view.window?.frame
        let buttonWin = statusItem?.button?.window
        let buttonWinFrame = buttonWin?.frame
        let buttonScreen = buttonWin?.screen
        let buttonY = buttonWinFrame?.origin.y ?? -1
        let screenH = buttonScreen?.frame.height ?? -1
        let isMenuBarHidden = buttonScreen != nil && buttonY >= screenH
        log("AppDelegate › resizeAndRepositionPanel — "
            + "preferred=(\(preferred.width),\(preferred.height)) "
            + "clamped=(\(newW),\(newH)) "
            + "current=(\(currentSize.width),\(currentSize.height)) "
            + "popoverWin=\(String(describing: popoverWinFrame)) "
            + "buttonWin=\(String(describing: buttonWinFrame)) "
            + "buttonScreen=\(String(describing: buttonScreen?.frame)) "
            + "buttonY=\(buttonY) screenH=\(screenH) "
            + "isMenuBarHidden=\(isMenuBarHidden) "
            + "pinnedOriginX=\(String(describing: pinnedPopoverOriginX)) "
            + "frameObserverInstalled=\(windowFrameObservation != nil)")
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            log("AppDelegate › resizeAndRepositionPanel — WRITING contentSize=(\(newW),\(newH)) "
                + "delta=(\(newW - currentSize.width),\(newH - currentSize.height)) "
                + "popoverWin.pre=\(String(describing: popoverWinFrame))")
            popover.contentSize = NSSize(width: newW, height: newH)
            let postWriteFrame = popover.contentViewController?.view.window?.frame
            log("AppDelegate › resizeAndRepositionPanel — contentSize written "
                + "popoverWin.post=\(String(describing: postWriteFrame)) "
                + "pinnedOriginX=\(String(describing: pinnedPopoverOriginX))")
        } else {
            log("AppDelegate › resizeAndRepositionPanel — no-op: size unchanged (delta within 1pt)")
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view` and defers resize.
    /// ❌ NEVER call synchronously — always deferred. See #2234.
    func navigate(to view: AnyView) {
        log("AppDelegate › navigate(to:) — rootView swap, deferring resize (fix/#2234)")
        hostingController?.rootView = view
        Task { @MainActor [weak self] in
            log("AppDelegate › navigate(to:) deferred Task — calling resizeAndRepositionPanel")
            self?.resizeAndRepositionPanel()
            log("AppDelegate › navigate(to:) deferred Task — done")
        }
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismiss

    /// Shared teardown called by every close/hide path.
    @MainActor
    func tearDownOpenState() {
#if DEBUG
        log("AppDelegate › tearDownOpenState — caller=\(Thread.callStackSymbols[1])")
#endif
        // fix/#2239: remove frame KVO before panelIsOpen is cleared so the
        // observer cannot fire on AppKit cleanup writes during dismissal.
        log("AppDelegate › tearDownOpenState — removing windowFrameObservation "
            + "pinnedOriginX=\(String(describing: pinnedPopoverOriginX)) "
            + "observerWasInstalled=\(windowFrameObservation != nil)")
        windowFrameObservation = nil
        pinnedPopoverOriginX = nil
        lifecycleCoordinator.tearDown()
        panelVisibilityState.isOpen = false
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// ❌ Do NOT call from outside-tap / workspace-switch — use hidePanel().
    func closePanel() {
        log("AppDelegate › closePanel — panelIsOpen=\(panelIsOpen)")
        guard panelIsOpen else {
            log("AppDelegate › closePanel — guard exit: not open")
            return
        }
        popover?.performClose(nil)
        lifecycleCoordinator.setPreservedSheetWindowHide(false)
        tearDownOpenState()
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
        hostingController?.rootView = mainView()
    }

    /// Hides the popover on outside-tap or workspace app-switch.
    /// ❌ NEVER add dismissSheets() here.
    /// ❌ NEVER reset hostingController.rootView here.
    func hidePanel() {
#if DEBUG
        let behavior = popover?.behavior.rawValue ?? -1
        let caller = Thread.callStackSymbols[1]
        log("AppDelegate › hidePanel — ENTER panelIsOpen=\(panelIsOpen) "
            + "hasActiveSheet=\(hasActiveSheet) preservedSheetWindowHide=\(preservedSheetWindowHide) "
            + "popoverBehavior=\(behavior) caller=\(caller)")
#endif
        guard panelIsOpen else {
            log("AppDelegate › hidePanel — guard exit: not open")
            return
        }
        panelSheetState.captureTransientHideState()
        panelVisibilityState.isTransientHide = true
        if hidePopoverWindowsPreservingSheets() {
            tearDownOpenState()
            return
        }
        popover?.performClose(nil)
        tearDownOpenState()
    }

    /// Orders the popover and attached sheet windows out without closing them.
    @discardableResult
    func hidePopoverWindowsPreservingSheets() -> Bool {
        let popoverWin = String(describing: popover?.contentViewController?.view.window)
        log("AppDelegate › hidePopoverWindowsPreservingSheets — ENTER "
            + "hasActiveSheet=\(hasActiveSheet) popoverWindow=\(popoverWin)")
        guard hasActiveSheet,
              let popoverWindow = popover?.contentViewController?.view.window else {
            log("AppDelegate › hidePopoverWindowsPreservingSheets — guard fail "
                + "(hasActiveSheet=\(hasActiveSheet) popoverWindow=\(popoverWin)), returning false")
            return false
        }
        log("AppDelegate › hidePopoverWindowsPreservingSheets — ordering out popoverWindow=\(popoverWindow) sheets=\(popoverWindow.sheets.count)")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderOut(nil)
        }
        lifecycleCoordinator.setPreservedSheetWindowHide(true)
        log("AppDelegate › hidePopoverWindowsPreservingSheets — done, preservedSheetWindowHide=true")
        return true
    }

    /// Restores windows hidden by `hidePopoverWindowsPreservingSheets()`.
    @discardableResult
    func restorePopoverWindowsPreservingSheetsIfNeeded() -> Bool {
        guard preservedSheetWindowHide,
              let popoverWindow = popover?.contentViewController?.view.window else { return false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderFront(nil)
        }
        lifecycleCoordinator.setPreservedSheetWindowHide(false)
        return true
    }

    /// Makes the lazy NSPopover backing window key immediately after show/restore.
    func makePopoverWindowKeyIfPossible() {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKey()
    }

    // MARK: - fix/#2239: window frame KVO snap helper

    /// Installs the window frame KVO observer that snaps x back to
    /// `pinnedPopoverOriginX` when AppKit corrupts it under auto-hide menubar.
    ///
    /// Must be called AFTER `popover.show()` so `pinnedPopoverOriginX` reflects
    /// the true post-show anchor position.
    /// ❌ NEVER wrap the observer body in Task { @MainActor } — the snap must
    /// fire synchronously before AppKit composites the window.
    func installWindowFrameSnapObserver(on popoverWindow: NSWindow) {
        let pinned = popoverWindow.frame.origin.x
        pinnedPopoverOriginX = pinned
        log("AppDelegate › installWindowFrameSnapObserver — pinnedPopoverOriginX=\(pinned) "
            + "popoverWindow=\(popoverWindow.frame)")
        windowFrameObservation = popoverWindow.observe(
            \.frame,
            options: [.old, .new]
        ) { [weak self] win, change in
            guard let self else { return }
            guard let newFrame = change.newValue,
                  let oldFrame = change.oldValue else { return }
            guard let pinnedX = self.pinnedPopoverOriginX else { return }
            let buttonY = self.statusItem?.button?.window?.frame.origin.y ?? -1
            let screenH = self.statusItem?.button?.window?.screen?.frame.height ?? -1
            let isMenuBarHidden = screenH > 0 && buttonY >= screenH
            log("AppDelegate › windowFrameObservation — "
                + "old=\(oldFrame) new=\(newFrame) "
                + "pinnedX=\(pinnedX) "
                + "buttonY=\(buttonY) screenH=\(screenH) "
                + "isMenuBarHidden=\(isMenuBarHidden) "
                + "xDrift=\(newFrame.origin.x - pinnedX)")
            guard isMenuBarHidden else {
                log("AppDelegate › windowFrameObservation — menubar visible, no snap needed")
                return
            }
            guard abs(newFrame.origin.x - pinnedX) > 1 else {
                log("AppDelegate › windowFrameObservation — x within 1pt of pinned, no snap needed")
                return
            }
            log("AppDelegate › windowFrameObservation — SNAP "
                + "x from \(newFrame.origin.x) back to \(pinnedX) "
                + "(isMenuBarHidden=true buttonY=\(buttonY) screenH=\(screenH)) "
                + "height=\(newFrame.size.height) preserved")
            var corrected = newFrame
            corrected.origin.x = pinnedX
            win.setFrameOrigin(corrected.origin)
            let snapFrame = win.frame
            log("AppDelegate › windowFrameObservation — post-snap frame=\(snapFrame)")
        }
        log("AppDelegate › installWindowFrameSnapObserver — observer installed (fix/#2239)")
    }

    // MARK: - Toggle

    /// Toggles the popover: opens it if closed, closes it if open.
    @objc func togglePanel() {
        log("AppDelegate › togglePanel — panelIsOpen=\(panelIsOpen)")
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    /// ⚠️ show() is called ONCE per open. Resize is done via contentSize only.
    func openPanel() {
        guard let button = statusItem?.button, let popover else {
            log("AppDelegate › openPanel — guard exit: button=\(statusItem?.button != nil) popover=\(self.popover != nil)")
            return
        }
        log("AppDelegate › openPanel — ENTER button.bounds=\(button.bounds) "
            + "button.window.frame=\(String(describing: button.window?.frame)) "
            + "button.window.screen=\(String(describing: button.window?.screen?.frame))")
        lifecycleCoordinator.setPanelIsOpen(true)
        panelVisibilityState.isOpen = true
        if !restorePopoverWindowsPreservingSheetsIfNeeded() {
            let hideArrow = !AppPreferencesStore.shared.showPopoverArrow
            if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
                popover.setValue(hideArrow, forKey: "shouldHideAnchor")
            }
            popover.behavior = .applicationDefined
            popover.delegate = self
            log("AppDelegate › openPanel — PRE-SHOW "
                + "behavior=\(popover.behavior.rawValue) "
                + "button.bounds=\(button.bounds) "
                + "button.window=\(String(describing: button.window?.frame))")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            log("AppDelegate › openPanel — POST-SHOW "
                + "popoverWindow.frame=\(String(describing: popover.contentViewController?.view.window?.frame))")
            // fix/#2239: install frame KVO snap AFTER show() so pinnedOriginX
            // reflects the true post-show anchor x, not a stale value.
            if let popoverWindow = popover.contentViewController?.view.window {
                installWindowFrameSnapObserver(on: popoverWindow)
            } else {
                log("AppDelegate › openPanel — fix/#2239 WARNING: popoverWindow nil after show(), observer NOT installed")
            }
        } else {
            log("AppDelegate › openPanel — restored preserved sheet window, skipping show()")
        }
        makePopoverWindowKeyIfPossible()
        // fix/#2234: defer resize + nav-restore to next main-actor turn so AppKit
        // commits the show() anchor before we touch contentSize.
        log("AppDelegate › openPanel — scheduling deferred resize+nav Task (fix/#2234)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            log("AppDelegate › openPanel deferred Task — ENTER "
                + "popoverWindow.frame=\(String(describing: self.popover?.contentViewController?.view.window?.frame)) "
                + "button.window.frame=\(String(describing: self.statusItem?.button?.window?.frame))")
            self.resizeAndRepositionPanel()
            if let saved = self.appState.savedNavState,
               !self.hasActiveSheet,
               let restored = self.validatedView(for: saved) {
                log("AppDelegate › openPanel deferred Task — restoring savedNavState=\(saved)")
                self.navigate(to: restored)
            } else {
                log("AppDelegate › openPanel deferred Task — no savedNavState "
                    + "(savedNavState=\(String(describing: self.appState.savedNavState)) "
                    + "hasActiveSheet=\(self.hasActiveSheet))")
            }
            log("AppDelegate › openPanel deferred Task — done")
        }
        Task { @MainActor [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }
        lifecycleCoordinator.installMonitors(
            hasActiveSheet: { [weak self] in
                guard let self else { return false }
                return self.hasActiveSheet || self.lifecycleCoordinator.isSheetDismissing
                    || self.overlayGate.hasActiveOverlay
            },
            popoverWindow: { [weak self] in self?.popover?.contentViewController?.view.window },
            onHide: { [weak self] in self?.hidePanel() }
        )
        log("AppDelegate › openPanel — monitors installed via lifecycleCoordinator")
    }
}
