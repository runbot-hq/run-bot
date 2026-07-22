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
// SIDE-JUMP UNDER AUTO-HIDE MENUBAR — fix #2232/#2233:
// navigate(to:) previously called resizeAndRepositionPanel() synchronously
// before SwiftUI had finished laying out the new view. This caused two rapid
// contentSize writes per view switch:
//   1. Synchronous call in navigate(to:)  — stale preferredContentSize
//   2. KVO observer Task (ms later)       — correct new preferredContentSize
// Under auto-hide menubar geometry, AppKit's two repositioning passes resolved
// to different x-origins → side-jump. Fix: remove the synchronous call.
// The KVO observer is the single source of truth for contentSize updates.
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
    /// App-owned — RunBot manages the dynamic icon observation task and button
    /// action directly. MBKPopoverController is NOT used in PR-A.
    var statusItem: NSStatusItem?
    /// The NSPopover that hosts the SwiftUI panel (replaces the old KeyablePanel/NSPanel approach).
    var popover: NSPopover?
    /// The SwiftUI hosting controller embedded inside `popover`. Its `rootView` is
    /// swapped on navigation; the controller itself is never recreated.
    var hostingController: NSHostingController<AnyView>?

    /// Gate that tracks whether a sheet or file-picker overlay is active.
    ///
    /// Lives on AppDelegate (not AppState) for PR-A so MenuBarKit stays decoupled
    /// from RunBot's domain model. Injected into the SwiftUI view tree via
    /// `.environment(overlayGate)` in `wrapEnv(_:)`. Views use this to call
    /// `.mbkSheet(overlayGate:)` and `mbkOpenFilePicker()` instead of bare
    /// `.sheet()` / `NSOpenPanel`, giving the outside-click monitor structural
    /// truth about overlay presence via `overlayGate.hasActiveOverlay`.
    let overlayGate = MBKOverlayGate()

    /// Sheet state that must survive transient popover hides.
    /// Stays on AppDelegate (wiring concern — not domain state). See issue #2040.
    let panelSheetState = PanelSheetState()
    /// Owns `panelIsOpen`, `preservedSheetWindowHide`, the global NSEvent
    /// outside-click monitor, and the NSWorkspace app-switch observer.
    /// AppDelegate is reduced to a wiring layer for these concerns (#1374).
    let lifecycleCoordinator = PopoverLifecycleCoordinator()
    /// KVO observation token for `NSHostingController.preferredContentSize`.
    /// Drives popover resize without re-calling `popover.show()`.
    var sizeObservation: NSKeyValueObservation?
    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// Shared observable that tracks whether the panel is open.
    /// Injected into every SwiftUI view via `wrapEnv(_:)`.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()
    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    /// Forwarded from `lifecycleCoordinator` for read access across AppDelegate extensions.
    /// Extensions read via this computed var; writes go via `lifecycleCoordinator.setPanelIsOpen(_:)`.
    var panelIsOpen: Bool { lifecycleCoordinator.panelIsOpen }
    /// Forwarded from `lifecycleCoordinator` for read access across AppDelegate extensions.
    /// Extensions read via this computed var; writes go via `lifecycleCoordinator.setPreservedSheetWindowHide(_:)`.
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
    /// Every view produced by a view-factory in AppDelegate+Navigation.swift must
    /// pass through this helper.
    /// ❌ NEVER remove `panelVisibilityState` from the environment injection here.
    /// `PanelContainerView` and its dim overlay observe this object;
    /// removing it causes a runtime crash on sheet dismissal.
    func wrapEnv<V: View>(_ view: V) -> AnyView {
        // Capture lifecycleCoordinator weakly so the environment closure cannot
        // extend AppDelegate's lifetime if AppDelegate is ever shortened. In
        // normal app lifetime AppDelegate is never released, but [weak self]
        // is the defensive correct pattern for closure captures on classes.
        let suppressHidePanel: @MainActor @Sendable () -> Void = { [weak self] in
            self?.lifecycleCoordinator.suppressHidePanel()
        }
        return AnyView(view
            .environment(panelVisibilityState)
            .environment(appState)          // top-level domain coordinator (issue #2040)
            .environment(overlayGate)
            .environment(\.suppressHidePanel, suppressHidePanel)
        )
    }

    // MARK: - Popover resize

    /// Clamps the popover's `contentSize` to the current screen bounds and writes it.
    ///
    /// This is the ONLY place that writes `popover.contentSize` while the popover
    /// is open. It is called exclusively from the KVO observer on
    /// `preferredContentSize` (AppDelegate+PanelSetup.swift) and from `openPanel()`
    /// (once, at open time, after `show()`).
    ///
    /// ⚠️ SIDE-JUMP GUARD (#2232/#2233):
    /// Do NOT call this from `navigate(to:)`. Doing so causes two rapid
    /// contentSize writes per view switch (one synchronous with stale size,
    /// one deferred from KVO with the correct size). Under auto-hide menubar
    /// geometry AppKit resolves each write's repositioning pass to a different
    /// x-origin → side-jump. The KVO observer is the single source of truth.
    ///
    /// ⚠️ Never call `popover.show()` here — updating `contentSize` resizes in place
    /// without re-anchoring the arrow.
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: panelIsOpen=\(panelIsOpen) popover=\(popover != nil) controller=\(hostingController != nil)")
            return
        }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else {
            log("AppDelegate › resizeAndRepositionPanel — guard exit: preferredContentSize.height=\(preferred.height) (not yet laid out)")
            return
        }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        let buttonScreenFrame = statusItem?.button?.window?.convertToScreen(
            statusItem?.button?.frame ?? .zero
        ) ?? .zero
        let visibleFrame = statusItemScreen.visibleFrame
        let autoHide = !NSMenu.menuBarVisible()
        // Build log string in parts to avoid Swift type-checker timeout on
        // long string-interpolation chains (#2235 compiler fix).
        let logMsg = "AppDelegate › resizeAndRepositionPanel"
            + " preferred=(\(preferred.width),\(preferred.height))"
            + " clamped=(\(newW),\(newH))"
            + " current=(\(currentSize.width),\(currentSize.height))"
            + " buttonScreenFrame=\(buttonScreenFrame)"
            + " visibleFrame=\(visibleFrame)"
            + " autoHideMenubar=\(autoHide)"
        log(logMsg)
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            let dw = newW - currentSize.width
            let dh = newH - currentSize.height
            log("AppDelegate › resizeAndRepositionPanel — WRITING contentSize=(\(newW),\(newH)) delta=(\(dw),\(dh))")
            popover.contentSize = NSSize(width: newW, height: newH)
            let postFrame = popover.contentViewController?.view.window?.frame ?? .zero
            log("AppDelegate › resizeAndRepositionPanel — POST-WRITE popoverWindowFrame=\(postFrame)")
        } else {
            log("AppDelegate › resizeAndRepositionPanel — no-op: size unchanged within 1pt")
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view`.
    /// The popover arrow stays pinned. Size update is handled exclusively
    /// by the KVO observer on `preferredContentSize` once SwiftUI finishes layout.
    ///
    /// ⚠️ Do NOT call resizeAndRepositionPanel() here — see resizeAndRepositionPanel()
    /// doc comment for the auto-hide side-jump explanation (#2232/#2233).
    ///
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    /// Calling directly from a SwiftUI view creates a retain cycle via the
    /// closure capture and bypasses the actor-safe callback path.
    func navigate(to view: AnyView) {
        let beforeSize = popover?.contentSize ?? .zero
        let beforePreferred = hostingController?.preferredContentSize ?? .zero
        let autoHide = !NSMenu.menuBarVisible()
        let btnScreenFrame = statusItem?.button?.window?.convertToScreen(
            statusItem?.button?.frame ?? .zero
        ) ?? .zero
        // Build log string in parts to avoid Swift type-checker timeout on
        // long string-interpolation chains (#2235 compiler fix).
        let enterMsg = "AppDelegate › navigate — ENTER"
            + " beforeContentSize=(\(beforeSize.width),\(beforeSize.height))"
            + " beforePreferred=(\(beforePreferred.width),\(beforePreferred.height))"
            + " autoHideMenubar=\(autoHide)"
            + " buttonScreenFrame=\(btnScreenFrame)"
        log(enterMsg)
        hostingController?.rootView = view
        let afterPreferred = hostingController?.preferredContentSize ?? .zero
        log("AppDelegate › navigate — rootView swapped afterPreferred=(\(afterPreferred.width),\(afterPreferred.height)) (KVO will fire when SwiftUI finishes layout)")
        // ⚠️ FIX #2232: resizeAndRepositionPanel() intentionally NOT called here.
        // Previously this line caused a double contentSize write on every view switch:
        //   1. Here — synchronous, stale preferredContentSize (SwiftUI not yet laid out)
        //   2. KVO observer Task — correct new preferredContentSize
        // Two rapid writes → two AppKit repositioning passes → different x-origins
        // under auto-hide menubar geometry → side-jump.
        // The KVO observer is the single source of truth for contentSize.
    }

    // MARK: - Make key for text input

    /// Promotes the app to key so TextFields in the popover receive input.
    func makeKeyForTextInput() {
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Dismiss

    /// Shared teardown called by every close/hide path.
    /// Resets `panelIsOpen` and the visibility state flag.
    /// Internal (not private) — called cross-file from AppDelegate+PanelSetup.swift.
    /// ⚠️ Must be called on the main actor. AppDelegate is @MainActor;
    /// do not call from background threads or completion handlers.
    /// Does NOT reset `savedNavState` — callers that want a full close (not a hide)
    /// must nil it out themselves (see `closePanel()`).
    /// Does NOT reset `panelVisibilityState.isTransientHide` — that flag is cleared
    /// by `openPanel()` on re-open.
    /// Note: the `Thread.callStackSymbols` log line below is wrapped in `#if DEBUG`
    /// and compiles away completely in release builds.
    @MainActor
    func tearDownOpenState() {
#if DEBUG
        log("AppDelegate › tearDownOpenState — caller=\(Thread.callStackSymbols[1])")
#endif
        // Order matters: coordinator clears panelIsOpen first, then SwiftUI state follows.
        // Both are @MainActor so there is no concurrency gap between the two writes,
        // but panelIsOpen must be false before panelVisibilityState.isOpen triggers
        // any onChange observer that reads panelIsOpen.
        lifecycleCoordinator.tearDown()
        panelVisibilityState.isOpen = false
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets rootView to main so next open starts fresh.
    /// ❌ Do NOT call this from outside-tap / workspace-switch — use hidePanel().
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
    ///
    /// Called directly by `outsideClickMonitor` and `workspaceObserver` (both installed in `openPanel()`).
    /// Intentionally does NOT call dismissSheets() and does NOT reset rootView.
    /// The NSHostingController and its SwiftUI @State (including any open sheet
    /// bindings) remain alive. On re-open, popover.show() reattaches the same
    /// controller and SwiftUI re-presents the sheet automatically.
    ///
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
        // ❌ Set isTransientHide = true BEFORE isOpen = false.
        // PanelContainerView.onChange fires synchronously when isOpen changes.
        // If isTransientHide is not already true at that point, onChange will
        // incorrectly clear isSheetActive, causing the dim-overlay animation to
        // replay on the next restore even though the sheet never closed.
        // See PanelVisibilityState.isTransientHide for the full lifecycle.
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

    // MARK: - Toggle

    /// Toggles the popover: opens it if closed, closes it if open.
    /// Called by the NSStatusItem button action.
    @objc func togglePanel() {
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Open

    /// Shows the popover anchored to the status bar button.
    /// ⚠️ show() is called ONCE per open. Resize is done via contentSize only.
    func openPanel() {
        guard let button = statusItem?.button, let popover else { return }
        log("AppDelegate › openPanel — LocalRunnerStore pushes state on every cycle, no seed needed")
        lifecycleCoordinator.setPanelIsOpen(true)
        panelVisibilityState.isOpen = true
        if !restorePopoverWindowsPreservingSheetsIfNeeded() {
            let hideArrow = !AppPreferencesStore.shared.showPopoverArrow
            if popover.responds(to: NSSelectorFromString("setShouldHideAnchor:")) {
                popover.setValue(hideArrow, forKey: "shouldHideAnchor")
            }
            popover.behavior = .applicationDefined
            popover.delegate = self
            let autoHide = !NSMenu.menuBarVisible()
            let btnScreenFrame = button.window?.convertToScreen(button.frame) ?? .zero
            let vFrame = statusItemScreen.visibleFrame
            // Build log string in parts to avoid Swift type-checker timeout on
            // long string-interpolation chains (#2235 compiler fix).
            let preShowMsg = "AppDelegate › openPanel — PRE-SHOW"
                + " behavior=\(popover.behavior.rawValue)"
                + " delegate=\(String(describing: popover.delegate))"
                + " buttonBounds=\(button.bounds)"
                + " buttonScreenFrame=\(btnScreenFrame)"
                + " visibleFrame=\(vFrame)"
                + " autoHideMenubar=\(autoHide)"
            log(preShowMsg)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let postWinFrame = popover.contentViewController?.view.window?.frame ?? .zero
            log("AppDelegate › openPanel — POST-SHOW behavior=\(popover.behavior.rawValue) popoverWindowFrame=\(postWinFrame)")
        }
        makePopoverWindowKeyIfPossible()
        resizeAndRepositionPanel()
        if let saved = appState.savedNavState, !hasActiveSheet, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
        Task { @MainActor [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }
        lifecycleCoordinator.installMonitors(
            // hasActiveSheet must also cover the sheet-dismissing window:
            // suppressHidePanel() sets isSheetDismissing = true for one run-loop
            // turn while the sheet animates out. Without this OR, an outside-click
            // Task queued just before Dismiss is tapped would read hasActiveSheet=false
            // (sheet already detached) and close the popover while it is still
            // visually animating — making suppressHidePanel() a silent no-op.
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
