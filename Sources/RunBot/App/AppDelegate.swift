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
// WHAT DOES NOT WORK:
//   1. Guarding contentSize writes in resizeAndRepositionPanel() — not in the
//      call path when sizingOptions = .preferredContentSize is active.
//   2. button.window.screen == nil as signal — screen association is retained
//      even while the menubar is hidden.
//   3. Removing sizingOptions = .preferredContentSize — stops the jump but
//      also stops NSHostingController computing preferredContentSize, freezing
//      the popover at initial size.
//
// CORRECT FIX — GuardedPopover contentSize override (fix/#2239):
// GuardedPopover subclasses NSPopover and overrides the contentSize setter.
// The setter evaluates isMenuBarHidden (buttonY >= screenH) using a lazy
// statusItemProvider closure (not a stored ref, because setupPanel() runs
// before setupStatusItem()). When hidden, the write is skipped; the current
// size is already correct. When visible, the write proceeds normally.
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
    /// The GuardedPopover (NSPopover subclass) that hosts the SwiftUI panel.
    ///
    /// ⚠️ MUST be typed as GuardedPopover? — NOT NSPopover?.
    /// Swift uses static dispatch on the declared property type for override
    /// resolution. If typed as NSPopover?, contentSize writes go directly to
    /// NSPopover's base-class implementation and GuardedPopover's override
    /// (which applies the isMenuBarHidden guard) is NEVER called.
    /// See fix/#2239 and the SIDE-JUMP note in the file header.
    var popover: GuardedPopover?
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

    // MARK: - fix/#2239: window frame KVO snap
    //
    // Captures the correct x-origin immediately after popover.show() and
    // installs a KVO observer on popoverWindow.frame. When AppKit corrupts
    // the x-origin (collapses to 0) during a contentSize write while the
    // auto-hide menubar is hidden, the observer snaps x back synchronously
    // before the window is composited. Height and width changes are preserved.
    // Both properties are reset in tearDownOpenState().
    // ❌ NEVER nil windowFrameObservation before tearDownOpenState() — doing so
    // removes the snap guard while the popover is still open.

    /// X-origin of the popover window captured immediately after popover.show().
    /// Used by windowFrameObservation to detect and correct AppKit side-jumps
    /// when the auto-hide menubar is hidden. Reset in tearDownOpenState().
    var pinnedPopoverOriginX: CGFloat?

    /// KVO observation on the popover window's NSWindow.frame.
    /// Fires synchronously on frame changes, before compositing.
    /// Snaps x back to pinnedPopoverOriginX when AppKit corrupts it while
    /// the auto-hide menubar is hidden (buttonY >= screenH).
    /// Installed in openPanel(), removed in tearDownOpenState().
    var windowFrameObservation: NSKeyValueObservation?

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

    /// Clamps the popover's `contentSize` to the current screen bounds.
    /// Called after every rootView swap (deferred) and from the KVO size observer (deferred).
    /// ⚠️ Never call `popover.show()` here — updating `contentSize` resizes in place
    /// without re-anchoring the arrow.
    /// ⚠️ Never call this synchronously from navigate(to:) or openPanel() — always
    /// via a deferred Task { @MainActor } to prevent side-jump with auto-hide menu bar.
    /// See issue #2234 and DEFERRED RESIZE note in the file header.
    /// ⚠️ fix/#2239: contentSize writes are intercepted by GuardedPopover.contentSize
    /// setter which applies the isMenuBarHidden guard. No guard needed here.
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
            + "isMenuBarHidden=\(isMenuBarHidden)")
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            log("AppDelegate › resizeAndRepositionPanel — WRITING contentSize=(\(newW),\(newH)) "
                + "delta=(\(newW - currentSize.width),\(newH - currentSize.height)) "
                + "popoverWin.pre=\(String(describing: popoverWinFrame))")
            popover.contentSize = NSSize(width: newW, height: newH)
            let postWriteFrame = popover.contentViewController?.view.window?.frame
            log("AppDelegate › resizeAndRepositionPanel — contentSize written "
                + "popoverWin.post=\(String(describing: postWriteFrame))")
        } else {
            log("AppDelegate › resizeAndRepositionPanel — no-op: size unchanged (delta within 1pt)")
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view` and defers the popover
    /// resize to the next main-actor scheduling turn.
    ///
    /// The resize is deferred via `Task { @MainActor }` (fix/#2234). With macOS
    /// menu bar auto-hide enabled, a synchronous `contentSize` write on the same
    /// run-loop turn as the rootView swap causes AppKit to re-solve the arrow anchor
    /// against the off-screen button geometry, producing a lateral jump. Deferring
    /// ensures AppKit has committed the anchor before the resize write arrives.
    ///
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    /// Calling directly from a SwiftUI view creates a retain cycle via the
    /// closure capture and bypasses the actor-safe callback path.
    /// ❌ NEVER remove the Task deferral and call resizeAndRepositionPanel()
    /// synchronously here — that reintroduces the auto-hide side-jump. See #2234.
    func navigate(to view: AnyView) {
        log("AppDelegate › navigate(to:) — rootView swap, deferring resize (fix/#2234)")
        hostingController?.rootView = view
        // Defer contentSize write to next main-actor scheduling turn.
        // See DEFERRED RESIZE note in file header and issue #2234.
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
        log("AppDelegate › tearDownOpenState — removing windowFrameObservation "
            + "pinnedOriginX=\(String(describing: pinnedPopoverOriginX)) "
            + "observerWasInstalled=\(windowFrameObservation != nil)")
        windowFrameObservation = nil
        pinnedPopoverOriginX = nil
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

    // MARK: - Toggle

    /// Toggles the popover: opens it if closed, closes it if open.
    /// Called by the NSStatusItem button action.
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
        let buttonFrame = button.bounds
        let buttonWinFrame = button.window?.frame
        let buttonWinScreen = button.window?.screen?.frame
        log("AppDelegate › openPanel — ENTER button.bounds=\(buttonFrame) "
            + "button.window.frame=\(String(describing: buttonWinFrame)) "
            + "button.window.screen=\(String(describing: buttonWinScreen))")
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
            log("AppDelegate › openPanel — PRE-SHOW "
                + "behavior=\(popover.behavior.rawValue) "
                + "delegate=\(String(describing: popover.delegate)) "
                + "button.bounds=\(button.bounds) "
                + "button.window=\(String(describing: button.window?.frame))")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let postShowWinFrame = popover.contentViewController?.view.window?.frame
            log("AppDelegate › openPanel — POST-SHOW "
                + "behavior=\(popover.behavior.rawValue) "
                + "popoverWindow.frame=\(String(describing: postShowWinFrame))")

            if let popoverWindow = popover.contentViewController?.view.window {
                let pinned = popoverWindow.frame.origin.x
                pinnedPopoverOriginX = pinned
                log("AppDelegate › openPanel — fix/#2239 pinnedPopoverOriginX=\(pinned) "
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
                log("AppDelegate › openPanel — fix/#2239 windowFrameObservation installed")
            } else {
                log("AppDelegate › openPanel — fix/#2239 WARNING: popoverWindow nil after show(), "
                    + "windowFrameObservation NOT installed")
            }
        } else {
            log("AppDelegate › openPanel — restored preserved sheet window, skipping show()")
        }
        makePopoverWindowKeyIfPossible()

        log("AppDelegate › openPanel — scheduling deferred resize+nav Task (fix/#2234)")
        Task { @MainActor [weak self] in
            guard let self else {
                log("AppDelegate › openPanel deferred Task — self nil, skipping")
                return
            }
            let winFrameAtTask = self.popover?.contentViewController?.view.window?.frame
            let buttonBoundsAtTask = self.statusItem?.button?.bounds
            let buttonWinAtTask = self.statusItem?.button?.window?.frame
            log("AppDelegate › openPanel deferred Task — ENTER "
                + "popoverWindow.frame=\(String(describing: winFrameAtTask)) "
                + "button.bounds=\(String(describing: buttonBoundsAtTask)) "
                + "button.window.frame=\(String(describing: buttonWinAtTask))")
            self.resizeAndRepositionPanel()
            if let saved = self.appState.savedNavState,
               !self.hasActiveSheet,
               let restored = self.validatedView(for: saved) {
                log("AppDelegate › openPanel deferred Task — restoring savedNavState=\(saved)")
                self.navigate(to: restored)
            } else {
                log("AppDelegate › openPanel deferred Task — no savedNavState to restore "
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
