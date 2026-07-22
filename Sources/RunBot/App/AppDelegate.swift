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
// When the macOS auto-hide menubar is fully hidden (retracted into the top
// edge), the Dock pushes the NSStatusItem button's backing NSWindow off the
// top of the screen: buttonWin.frame.origin.y rises to >= screen.frame.height.
// In this state ANY contentSize write causes AppKit to re-run full anchor
// geometry against the off-screen button geometry, collapsing the popover
// x-origin to 0 (side-jump).
//
// CORRECT FIX — GuardedPopover contentSize override (fix/#2239):
// GuardedPopover subclasses NSPopover and overrides the contentSize setter.
// The setter evaluates isMenuBarHidden (screenH < 0 || buttonY >= screenH)
// using a lazy statusItemProvider closure (not a stored ref, because
// setupPanel() runs before setupStatusItem()). When hidden, the write is
// skipped; the current size is already correct. When visible, the write
// proceeds normally.
// sizingOptions = .preferredContentSize is kept so SwiftUI keeps publishing
// preferredContentSize — GuardedPopover intercepts before super.contentSize
// is written. This blocks ALL write paths (sizingOptions pipe AND manual
// resizeAndRepositionPanel) in one place.
// See AppDelegate+PanelSetup.swift and issue #2239.
//
// ⚠️ var popover MUST be typed as GuardedPopover? (not NSPopover?) so Swift
// dispatches contentSize writes through the override. If typed as NSPopover?,
// Swift uses static dispatch to the base class and the override is never called.
//
// isMenuBarHidden CORRECT SIGNAL (fix/#2239 + fix/#2240):
//   screenH < 0 || buttonY >= screenH
//
//   screenH < 0 means button.window.screen returned nil. The Dock slides the
//   NSStatusItem window fully off the screen when autohide retracts the bar,
//   and at that moment screen becomes nil → screenH = -1. This IS the hidden
//   state.
//
//   WRONG expressions (do not use):
//     screenH > 0 && buttonY >= screenH  ← evaluates false when screen==nil
//                                           (screenH=-1, `> 0` fails, guard skipped)
//
//   Observed in logs:
//     Hidden (screen nil):   buttonY=982,  screenH=-1   ← side-jump occurs here
//     Hidden (screen alive): buttonY=982,  screenH=982
//     Visible:               buttonY=949,  screenH=982
//
// PANELVISIBILITYSTATE:
// panelVisibilityState.isOpen is set in openPanel()/closePanel()/hidePanel().
// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
// See ARCHITECTURE.md §panelVisibilityState.
//
// SHEET STATE ACROSS HIDE/SHOW:
// When the user taps outside while a sheet is open, hidePanel() is called.
// Goal: re-opening the status bar icon should show settings WITH the sheet.
//
// How this works:
// - hidePanel() does NOT call dismissSheets() and does NOT reset rootView.
//   NSPopover's performClose() closes the NSPopoverWindowFrame and all its
//   child windows (including the sheet NSWindow) together. They are removed
//   from screen but the NSHostingController and its SwiftUI tree remain alive.
//   SwiftUI @State (editingRunner, showAddScopeSheet, etc.) is preserved inside
//   the hosting controller's view because the hosting controller itself is never
//   destroyed or replaced.
// - On re-open, openPanel() calls popover.show() which re-attaches the same
//   NSHostingController. SwiftUI sees the existing state, the binding is still
//   true, and re-presents the sheet automatically.
//
// closePanel() IS different: it is called when the user explicitly closes
// (e.g. pressing Escape, or navigating back). In that case we DO reset rootView
// to mainView() so the next open starts fresh at the main view.
//
// ❌ NEVER add dismissSheets() to hidePanel() — it destroys sheet @State.
// ❌ NEVER reset hostingController.rootView inside hidePanel().
// ❌ NEVER add a validatedView(for: .settings) navigate() call inside openPanel()
//    when the current rootView is already SettingsView — it replaces the live
//    view with a new struct and resets all @State.

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
    /// ❌ NEVER access domain sub-objects directly on AppDelegate once they
    ///    have been migrated to AppState. Use `appState.x` instead.
    let appState = AppState()

    /// The NSStatusItem anchoring the menu-bar icon and popover.
    var statusItem: NSStatusItem?

    /// The GuardedPopover (NSPopover subclass) that hosts the SwiftUI panel.
    /// ⚠️ MUST be typed as GuardedPopover? — NOT NSPopover?. Swift uses static
    /// dispatch on the declared type; NSPopover? skips the contentSize override.
    var popover: GuardedPopover?

    /// The SwiftUI hosting controller embedded inside `popover`. Its `rootView` is
    /// swapped on navigation; the controller itself is never recreated.
    var hostingController: NSHostingController<AnyView>?

    /// Gate that tracks whether a sheet or file-picker overlay is active.
    let overlayGate = MBKOverlayGate()

    /// Sheet state that must survive transient popover hides.
    let panelSheetState = PanelSheetState()

    /// Owns `panelIsOpen`, `preservedSheetWindowHide`, the global NSEvent
    /// outside-click monitor, and the NSWorkspace app-switch observer.
    let lifecycleCoordinator = PopoverLifecycleCoordinator()

    /// KVO observation token for `NSHostingController.preferredContentSize`.
    var sizeObservation: NSKeyValueObservation?

    // MARK: - fix/#2239: window frame KVO snap

    /// X-origin of the popover window captured immediately after popover.show().
    /// Used by `windowFrameObservation` to snap x back when AppKit corrupts it
    /// during a contentSize write while the auto-hide menubar is hidden.
    /// Reset in `tearDownOpenState()`.
    var pinnedPopoverOriginX: CGFloat?

    /// KVO observation on the popover window's `NSWindow.frame`.
    /// Fires synchronously before compositing; snaps x back to `pinnedPopoverOriginX`
    /// when `isMenuBarHidden` is true and AppKit collapses the origin to 0.
    /// Installed in `openPanel()` via `installWindowFrameSnap(on:pinned:)`.
    /// Removed in `tearDownOpenState()`.
    /// ❌ NEVER nil this before `tearDownOpenState()` — removes the snap guard.
    var windowFrameObservation: NSKeyValueObservation?

    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()

    /// Minimum popover content width.
    static let minWidth: CGFloat = 280

    /// Forwarded from `lifecycleCoordinator` for read access across extensions.
    var panelIsOpen: Bool { lifecycleCoordinator.panelIsOpen }

    /// Forwarded from `lifecycleCoordinator` for read access across extensions.
    var preservedSheetWindowHide: Bool { lifecycleCoordinator.preservedSheetWindowHide }

    /// Maximum popover content width (90% of screen, capped at 900).
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

    /// Wraps `view` in the shared environment objects required by the panel.
    /// Every view produced by a view-factory in `AppDelegate+Navigation.swift`
    /// must pass through this helper.
    /// ❌ NEVER remove `panelVisibilityState` — its absence crashes on sheet dismissal.
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
    /// Always call via `Task { @MainActor }` — never synchronously from
    /// `navigate(to:)` or `openPanel()` (causes auto-hide side-jump, fix/#2234).
    /// contentSize writes are guarded by `GuardedPopover` (fix/#2239).
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: "
                + "panelIsOpen=\(panelIsOpen) popover=\(popover != nil) "
                + "controller=\(hostingController != nil)")
            return
        }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: preferred.height <= 0")
            return
        }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        let buttonWin = statusItem?.button?.window
        let buttonY = buttonWin?.frame.origin.y ?? -1
        let screenH = buttonWin?.screen?.frame.height ?? -1
        log("AppDelegate › resizeAndRepositionPanel — "
            + "preferred=(\(preferred.width),\(preferred.height)) "
            + "clamped=(\(newW),\(newH)) current=(\(currentSize.width),\(currentSize.height)) "
            + "buttonY=\(buttonY) screenH=\(screenH)")
        guard abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 else {
            log("AppDelegate › resizeAndRepositionPanel — no-op: size unchanged")
            return
        }
        popover.contentSize = NSSize(width: newW, height: newH)
        log("AppDelegate › resizeAndRepositionPanel — wrote (\(newW),\(newH))")
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view` and defers resize.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    /// ❌ NEVER remove the Task deferral — reintroduces auto-hide side-jump (#2234).
    func navigate(to view: AnyView) {
        log("AppDelegate › navigate(to:) — rootView swap, deferring resize (fix/#2234)")
        hostingController?.rootView = view
        Task { @MainActor [weak self] in self?.resizeAndRepositionPanel() }
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive first-responder.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismiss

    /// Shared teardown called by every close/hide path.
    /// Removes `windowFrameObservation`, resets `panelIsOpen`, and clears
    /// `panelVisibilityState.isOpen`.
    /// ⚠️ Must be called on the main actor.
    @MainActor
    func tearDownOpenState() {
#if DEBUG
        log("AppDelegate › tearDownOpenState — caller=\(Thread.callStackSymbols[1])")
#endif
        log("AppDelegate › tearDownOpenState — removing windowFrameObservation "
            + "pinnedOriginX=\(String(describing: pinnedPopoverOriginX))")
        windowFrameObservation = nil
        pinnedPopoverOriginX = nil
        lifecycleCoordinator.tearDown()
        panelVisibilityState.isOpen = false
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets rootView to main so next open starts fresh.
    /// ❌ Do NOT call from outside-tap / workspace-switch — use `hidePanel()`.
    func closePanel() {
        log("AppDelegate › closePanel — panelIsOpen=\(panelIsOpen)")
        guard panelIsOpen else { return }
        popover?.performClose(nil)
        lifecycleCoordinator.setPreservedSheetWindowHide(false)
        tearDownOpenState()
        appState.savedNavState = nil
        panelSheetState.clearRunnerSheet()
        hostingController?.rootView = mainView()
    }

    /// Hides the popover on outside-tap or workspace app-switch.
    func hidePanel() {
#if DEBUG
        let behavior = popover?.behavior.rawValue ?? -1
        let caller = Thread.callStackSymbols[1]
        log("AppDelegate › hidePanel — ENTER panelIsOpen=\(panelIsOpen) "
            + "hasActiveSheet=\(hasActiveSheet) behavior=\(behavior) caller=\(caller)")
#endif
        guard panelIsOpen else { return }
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
        log("AppDelegate › hidePopoverWindowsPreservingSheets — hasActiveSheet=\(hasActiveSheet)")
        guard hasActiveSheet,
              let popoverWindow = popover?.contentViewController?.view.window else {
            log("AppDelegate › hidePopoverWindowsPreservingSheets — guard fail, returning false")
            return false
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            popoverWindow.orderOut(nil)
        }
        _ = popoverWin
        lifecycleCoordinator.setPreservedSheetWindowHide(true)
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

    // MARK: - Toggle

    /// Toggles the popover open/closed. Called by the NSStatusItem button action.
    @objc func togglePanel() {
        log("AppDelegate › togglePanel — panelIsOpen=\(panelIsOpen)")
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Window frame snap (fix/#2239)

    /// Installs a KVO observer on `popoverWindow.frame` that snaps the x-origin
    /// back to `pinnedX` whenever AppKit corrupts it (collapses to 0) during a
    /// contentSize write while `isMenuBarHidden` is true.
    /// Called once per open from `openPanel()`. Torn down in `tearDownOpenState()`.
    func installWindowFrameSnap(on popoverWindow: NSWindow, pinned pinnedX: CGFloat) {
        pinnedPopoverOriginX = pinnedX
        windowFrameObservation = popoverWindow.observe(\.frame, options: [.new]) {
            [weak self] win, change in
            guard let self, let newFrame = change.newValue else { return }
            guard let px = self.pinnedPopoverOriginX else { return }
            let buttonY = self.statusItem?.button?.window?.frame.origin.y ?? -1
            let screenH = self.statusItem?.button?.window?.screen?.frame.height ?? -1
            let isMenuBarHidden = screenH < 0 || buttonY >= screenH
            log("AppDelegate › windowFrameObservation — "
                + "new=\(newFrame) pinnedX=\(px) "
                + "buttonY=\(buttonY) screenH=\(screenH) "
                + "isMenuBarHidden=\(isMenuBarHidden) xDrift=\(newFrame.origin.x - px)")
            guard isMenuBarHidden, abs(newFrame.origin.x - px) > 1 else { return }
            log("AppDelegate › windowFrameObservation — SNAP x \(newFrame.origin.x) → \(px)")
            var corrected = newFrame
            corrected.origin.x = px
            win.setFrameOrigin(corrected.origin)
        }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    /// ⚠️ `show()` is called ONCE per open. Resize is done via `contentSize` only.
    func openPanel() {
        guard let button = statusItem?.button, let popover else {
            log("AppDelegate › openPanel — guard exit")
            return
        }
        log("AppDelegate › openPanel — ENTER button.bounds=\(button.bounds)")
        lifecycleCoordinator.setPanelIsOpen(true)
        panelVisibilityState.isOpen = true
        if !restorePopoverWindowsPreservingSheetsIfNeeded() {
            let hideArrow = !AppPreferencesStore.shared.showPopoverArrow
            if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
                popover.setValue(hideArrow, forKey: "shouldHideAnchor")
            }
            popover.behavior = .applicationDefined
            popover.delegate = self
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            log("AppDelegate › openPanel — POST-SHOW "
                + "popoverWindow=\(String(describing: popover.contentViewController?.view.window?.frame))")
            if let popoverWindow = popover.contentViewController?.view.window {
                installWindowFrameSnap(on: popoverWindow, pinned: popoverWindow.frame.origin.x)
                log("AppDelegate › openPanel — windowFrameSnap installed pinnedX=\(popoverWindow.frame.origin.x)")
            }
        }
        makePopoverWindowKeyIfPossible()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.resizeAndRepositionPanel()
            if let saved = self.appState.savedNavState,
               !self.hasActiveSheet,
               let restored = self.validatedView(for: saved) {
                self.navigate(to: restored)
            }
        }
        Task { @MainActor [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }
        lifecycleCoordinator.installMonitors(
            panelIsOpen: { [weak self] in self?.panelIsOpen ?? false },
            hasActiveOverlay: { [weak self] in self?.overlayGate.hasActiveOverlay ?? false },
            popoverFrame: { [weak self] in self?.popover?.contentViewController?.view.window?.frame },
            onHide: { [weak self] in self?.hidePanel() }
        )
        log("AppDelegate › openPanel — done")
    }
}
