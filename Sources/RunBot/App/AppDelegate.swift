// AppDelegate.swift
// RunBot

import AppKit
import AppUpdater
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

    /// The NSStatusItem anchoring the menu-bar icon and popover.
    var statusItem: NSStatusItem?
    /// The NSPopover that hosts the SwiftUI panel (replaces the old KeyablePanel/NSPanel approach).
    var popover: NSPopover?
    /// The SwiftUI hosting controller embedded inside `popover`. Its `rootView` is
    /// swapped on navigation; the controller itself is never recreated.
    var hostingController: NSHostingController<AnyView>?
    /// Owned OAuth service instance. Typed to protocol so tests can supply a stub
    /// without going through the live singleton (P7).
    ///
    /// Constructed once here — injected into `AppDelegate+OAuthCallback`, `AppDelegate+Polling`,
    /// and `SettingsView` rather than accessed via a global `.shared`.
    let oauthService: any OAuthServiceProtocol = OAuthService()
    /// Owned lifecycle service instance. Typed to protocol so tests can supply a stub
    /// without spawning real `svc.sh` processes (P7).
    ///
    /// Constructed once here — injected into `SettingsView` → `LocalRunnersView`
    /// rather than accessed via a global `.shared`.
    let lifecycleService: any RunnerLifecycleServiceProtocol = RunnerLifecycleService()
    /// Owned `LocalRunnerStore` actor.
    ///
    /// `lazy var` is required: `LocalRunnerStore.shared` is only valid after
    /// `LocalRunnerStore.configure(viewModel:)` is called in
    /// `applicationDidFinishLaunching`. A `let` default would be evaluated
    /// eagerly during `AppDelegate.init()` — before `configure()` runs —
    /// triggering the `fatalError` guard inside `LocalRunnerStore.shared`.
    lazy var localRunnerStore: LocalRunnerStore = .shared
    /// Owned `RunnerPoller` actor. `nil` until `setupSubscriptions()` runs.
    ///
    /// Optional (not `!`) so the uninitialised state is representable at the
    /// type level and the compiler flags any force-unwrap at call sites (P4).
    ///
    /// The sole init site is `AppDelegate+PanelSetup.swift` → `setupSubscriptions()`,
    /// which runs on the `@MainActor` and can therefore pass `AppPreferencesStore.shared`
    /// and `ScopeStore.shared` as explicit arguments.
    ///
    /// ❌ NEVER add a `lazy var` default body here — doing so creates a dual-init
    /// path: if anything reads `runnerStore` before `setupSubscriptions()` runs,
    /// a second `RunnerPoller` instance with live observation tasks would be created
    /// and immediately replaced, producing competing poll loops.
    var runnerStore: (any RunnerPollerProtocol)?
    /// The observable read model for Core-side runner/job/action/rate-limit state.
    ///
    /// Created here (not inside `setupSubscriptions`) so it survives for the full
    /// app lifetime and can be injected into the SwiftUI environment in `wrapEnv(_:)`.
    /// `RunnerPoller.applyFetchResult` writes into this instance on the `@MainActor`
    /// after every poll cycle; views read from it via `@Environment(RunnerState.self)`.
    /// `LocalRunnerStore` pushes `localRunners` and `isLocalScanning` into this instance
    /// via `LocalRunnerStore.configure(viewModel: runnerState)` in `setupSubscriptions()`.
    let runnerState = RunnerState()
    /// The auto-update driver. Carries all RunBot-specific configuration (repo
    /// slug, asset name, scheduler identifier, beta-channel source); the
    /// `AppUpdater` library itself holds no RunBot strings. Injected into
    /// `SettingsView` for the Install & Relaunch action and driven from
    /// `AppDelegate+PanelSetup` on startup.
    let autoUpdater = AppUpdater(
        repo: "runbot-hq/run-bot",
        currentVersion: Bundle.main.rbVersionString,
        assetName: { _ in "RunBot.zip" },
        schedulerIdentifier: "io.github.runbot-hq.update-check",
        betaChannelProvider: { AppPreferencesStore.shared.betaChannel }
    )
    /// The last nav destination the user was on before the popover was closed or hidden.
    /// Restored by `openPanel()` so the user lands back where they left off.
    var savedNavState: NavState?
    /// Sheet state that must survive transient popover hides.
    let panelSheetState = PanelSheetState()

    // periphery:ignore - write-only by design; assignment keeps the loop alive
    /// Retains the `ObservationLoop` that observes `runnerState.aggregateStatus`
    /// and calls `updateStatusIcon()` whenever the runner fleet status changes.
    /// Must be stored as a property — deallocating it stops re-registration.
    var statusIconLoop: ObservationLoop?

    // periphery:ignore - write-only by design; assignment keeps the Task alive
    /// Retained handle for the sign-out observation task started in
    /// `setupSignOutSubscription()` (AppDelegate+Polling.swift).
    /// Keeping a strong reference ensures the task is never silently abandoned.
    var signOutTask: Task<Void, Never>?
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
        AnyView(view
            .environment(panelVisibilityState)
            .environment(runnerState)
        )
    }

    // MARK: - Popover resize

    /// Clamps the popover's `contentSize` to the current screen bounds.
    /// Called after every rootView swap and from the KVO size observer.
    /// ⚠️ Never call `popover.show()` here — updating `contentSize` resizes in place
    /// without re-anchoring the arrow.
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        if abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1 {
            popover.contentSize = NSSize(width: newW, height: newH)
        }
    }

    // MARK: - Navigation

    /// Swaps the hosting controller's `rootView` to `view` and immediately
    /// recalculates the popover size. The popover arrow stays pinned.
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    /// Calling directly from a SwiftUI view creates a retain cycle via the
    /// closure capture and bypasses the actor-safe callback path.
    func navigate(to view: AnyView) {
        hostingController?.rootView = view
        resizeAndRepositionPanel()
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
        savedNavState = nil
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
            log("AppDelegate › openPanel — PRE-SHOW behavior=\(popover.behavior.rawValue) delegate=\(String(describing: popover.delegate))")
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            log("AppDelegate › openPanel — POST-SHOW behavior=\(popover.behavior.rawValue)")
        }
        makePopoverWindowKeyIfPossible()
        resizeAndRepositionPanel()
        if let saved = savedNavState, !hasActiveSheet, let restored = validatedView(for: saved) {
            navigate(to: restored)
        }
        Task { @MainActor [weak self] in
            guard let self, !self.preservedSheetWindowHide else { return }
            self.panelSheetState.restoreTransientHideStateIfNeeded()
        }
        lifecycleCoordinator.installMonitors(
            hasActiveSheet: { [weak self] in self?.hasActiveSheet ?? false },
            popoverWindow: { [weak self] in self?.popover?.contentViewController?.view.window },
            onHide: { [weak self] in self?.hidePanel() }
        )
        log("AppDelegate › openPanel — monitors installed via lifecycleCoordinator")
    }
}
