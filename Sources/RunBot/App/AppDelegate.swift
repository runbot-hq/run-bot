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
// 2. Shown via popover.show(relativeTo: positioningRect, of: button,
//    preferredEdge: .minY) — anchors to a 1pt sliver at the status item
//    button's horizontal midpoint (see positioningRect(for:) below and the
//    ANCHOR RECT note), NOT the full button bounds.
// 3. Size is driven by a GeometryReader baked into each content view by
//    navigate(to:) / setupPanel() via wrapWithSizeReporter(_:). The
//    GeometryReader lives INSIDE the AnyView boundary so it participates
//    in every layout pass, including async @Observable state changes.
//    See NavigationShell.swift for the full architecture.
// 4. Width is clamped to [minWidth..maxWidth] from screen bounds.
// 5. Dismiss: popover.performClose(nil) driven by the global NSEvent monitor
//    (outside clicks) and NSWorkspace app-switch notification.
//    See openPanel() for the monitor implementation.
//    See docs/graveyard.md for history of attempted alternatives.
//
// ANCHOR RECT — 1pt midX sliver, not full button.bounds (matches
// runbot-hq/MenuBarKit PR #6's positioningRect(for:)):
// NSPopover centers itself against whatever rect is passed to show() at
// show()-time. Passing the FULL button.bounds means that if the button's
// width shifts even slightly — e.g. during a menu-bar autohide reveal, while
// neighboring status items are still repositioning/settling — the popover's
// initial anchor point moves with it, independent of and prior to anything
// resizeAndRepositionPanel() does. Using a synthetic 1pt-wide rect pinned to
// bounds.midX removes that dependency: the anchor point is a single stable
// x-coordinate rather than a rect whose width can itself be in flux.
// positioningRect(for:) also guards against degenerate (zero width/height)
// button bounds, returning nil so callers can skip show() for that tick
// rather than anchoring to a meaningless rect.
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
// LATERAL JUMP PREVENTION — delta-based fix (matches runbot-hq/MenuBarKit #12 / PR #6):
//
// NSPopover only centers its window around the positioningRect ONCE, at
// show() time. After that, mutating contentSize alone causes AppKit to grow
// the window from its bottom-left corner — nothing re-runs the centering
// math, so the arrow stays pinned while the box drifts away from it.
//
// Failed approaches (full writeup in runbot-hq/MenuBarKit issue #12):
//   1. No correction — box drifts from arrow.
//   2. window.frame.midX offset by contentSize/2 — mixes chrome and content
//      coordinate spaces → systematic ~100pt offset (window to screen edge).
//   3. Re-querying button screen position on every resize — button Y is NOT
//      stable across sessions (auto-hide slides status bar off/on screen).
//   4. Reading window.frame AFTER writing contentSize — AppKit repositions
//      as a side-effect of the write, so frame is already stale.
//
// WORKING FIX: compute the DELTA and shift the EXISTING origin by it — never
// compute an absolute target position from button/screen coordinates:
//   let oldFrame = window.frame          // read BEFORE contentSize mutation
//   let dw = newW - currentSize.width
//   let dh = newH - currentSize.height
//   popover.contentSize = ...            // AppKit grows from bottom-left
//   newOrigin.x = oldFrame.origin.x - dw / 2   // grow symmetrically → midX fixed
//   newOrigin.y = oldFrame.origin.y - dh       // grow downward only → maxY fixed
// This works because: no absolute coordinates → no chrome/content space
// mismatch; no button position query → immune to auto-hide Y drift; oldFrame
// is captured before the mutation → not affected by AppKit's reposition
// side-effect. Purely relative math, correct on any screen/content size.
// This resize/reposition fix mirrors MenuBarKit PR #6 exactly and is NOT
// the fix for the open-time issue below — those are two independent bugs.
//
// ⚠️ INSTRUMENTATION + DEGENERATE-BASELINE GUARD:
// resizeAndRepositionPanel(preferredSize:) previously had ZERO logging, so a
// sidejump that happens WHILE the panel is already open (content grows as
// data streams in, e.g. workflow rows populating after open) was invisible
// in log dumps — every prior fix attempt was debugging the open-time anchor
// path (showPopoverRetryingIfNeeded) because that was the only instrumented
// one. Every call now logs oldFrame / dw / dh / newOrigin. Additionally, if
// the `oldFrame` read at the top of the function is degenerate — zero width
// or height, or origin.x == 0 while the status item's screen visibleFrame
// does NOT start at x == 0 — the delta shift is skipped and a warning is
// logged instead of propagating a bad baseline into window.setFrameOrigin().
//
// AUTOHIDE SIDE-JUMP AT OPEN TIME (separate issue from the above — NOT
// covered by MenuBarKit PR #6's applyContentSize, which only addresses
// resize/reposition):
// With "Automatically hide and show the menu bar" enabled, the click that
// triggers togglePanel() is often the SAME click that reveals the menu bar.
// showPopoverRetryingIfNeeded() used to accept the FIRST run-loop tick where
// button.window.frame looked non-zero and on-screen as "ready" — but during
// the reveal slide animation, the frame passes that check WHILE STILL MOVING.
// show() then anchors against a transitional (not-yet-final) frame; the menu
// bar finishes sliding a moment later, the button's real resting frame shifts,
// and the already-shown popover does not follow — producing a sidejump that
// only reproduces with autohide enabled. Fixed by requiring the frame to be
// IDENTICAL across two consecutive run-loop ticks (i.e. settled, not just
// "non-zero") before calling show(). See showPopoverRetryingIfNeeded() below.
// Combined with the 1pt-midX positioningRect above: settle-detection ensures
// we don't anchor mid-slide; the midX sliver ensures that even a small
// residual width jitter in the button doesn't itself become an anchor error.
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
// (e.g. pressing Escape, or navigating back). In that case we DO reset content
// to mainView() so the next open starts fresh at the main view.
//
// ❌ NEVER add dismissSheets() to hidePanel() — it destroys sheet @State.
// ❌ NEVER reset navigationShell.content inside hidePanel().
// ❌ NEVER add a validatedView(for: .settings) navigate() call inside openPanel()
//    when the current content is already SettingsView — it replaces the live
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
    /// The NSPopover that hosts the SwiftUI panel.
    var popover: NSPopover?
    /// The SwiftUI hosting controller embedded inside `popover`.
    /// Root is NavigationShellView — NEVER replaced. See NavigationShell.swift.
    var hostingController: NSHostingController<AnyView>?

    /// Permanent navigation slot. navigate(to:) writes content here.
    /// NavigationShellView reads it. Each content value has a GeometryReader
    /// baked in by navigate(to:) / setupPanel() — see NavigationShell.swift.
    ///
    /// ❌ NEVER replace hostingController.rootView after setupPanel().
    /// ❌ NEVER create a second NavigationShell.
    var navigationShell: NavigationShell?

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
    let panelSheetState = PanelSheetState()
    /// Owns `panelIsOpen`, `preservedSheetWindowHide`, the global NSEvent
    /// outside-click monitor, and the NSWorkspace app-switch observer.
    let lifecycleCoordinator = PopoverLifecycleCoordinator()
    // Regression guard — see ARCHITECTURE.md §panelVisibilityState.
    /// Shared observable that tracks whether the panel is open.
    /// ❌ NEVER remove. ❌ NEVER remove from wrapEnv().
    let panelVisibilityState = PanelVisibilityState()
    /// Minimum popover content width.
    static let minWidth: CGFloat = 280
    /// Forwarded from `lifecycleCoordinator` for read access across extensions.
    var panelIsOpen: Bool { lifecycleCoordinator.panelIsOpen }
    /// Forwarded from `lifecycleCoordinator` for read access across extensions.
    var preservedSheetWindowHide: Bool { lifecycleCoordinator.preservedSheetWindowHide }
    /// Maximum popover content width (90% of screen).
    var maxWidth: CGFloat { min(900, statusItemScreen.visibleFrame.width * 0.9) }
    /// Maximum popover height (85% of visible screen).
    var maxHeight: CGFloat { statusItemScreen.visibleFrame.height * 0.85 }
    /// The screen the status item lives on.
    var statusItemScreen: NSScreen {
        statusItem?.button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var showRetryCount = 0
    private static let maxShowRetries = 10
    private var lastObservedButtonFrame: NSRect?

    // MARK: - Sheet guard

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

    // MARK: - Size reporter wrapping

    /// Wraps a view with a background GeometryReader that drives popover sizing.
    ///
    /// Must be called BEFORE type-erasing to AnyView so the GeometryReader lives
    /// INSIDE the AnyView boundary — matching PR #6's pendingRootView wrapping in
    /// PopoverController.setupPopover(). Inside the boundary, the GeometryReader
    /// participates in every layout pass including async @Observable state changes.
    ///
    /// ❌ NEVER wrap the AnyView itself — the GeometryReader would sit outside the
    ///    boundary, miss async state-driven size changes, and only fire on
    ///    navigate() calls (when the AnyView box itself changes).
    func wrapWithSizeReporter<V: View>(_ view: V) -> AnyView {
        AnyView(
            view.background(
                GeometryReader { [weak self] geo in
                    Color.clear
                        .onAppear { self?.resizeAndRepositionPanel(preferredSize: geo.size) }
                        .onChange(of: geo.size) { _, newSize in
                            self?.resizeAndRepositionPanel(preferredSize: newSize)
                        }
                }
            )
        )
    }

    // MARK: - Popover resize

    /// Clamps `preferred` to the current screen bounds, then either records the
    /// size (when the popover is not yet shown) or corrects the window origin
    /// using a DELTA-based shift (when the popover is open).
    ///
    /// PRE-SHOW RECORDING (matches runbot-hq/MenuBarKit PR #6 applyContentSize):
    /// When the GeometryReader fires onAppear before the popover is fully shown,
    /// the size must be recorded into popover.contentSize rather than dropped.
    /// finishOpenPanel() reads fittingSize immediately after show() — if
    /// contentSize was updated here, fittingSize reflects the correct size and
    /// the popover opens at the right dimensions on the very first frame.
    ///
    /// POST-SHOW REPOSITION (see LATERAL JUMP PREVENTION note above):
    /// Called exclusively by GeometryReaders baked into content by
    /// wrapWithSizeReporter(_:). SwiftUI reports its own size directly; this
    /// function never reads `preferredContentSize` or any KVO-derived value.
    ///
    /// ⚠️ Every branch is logged — do not strip logging without first confirming
    /// the mid-session sidejump is closed (was invisible for multiple rounds
    /// because this function was previously silent).
    func resizeAndRepositionPanel(preferredSize preferred: CGSize) {
        guard let popover else { return }
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        let sizeChanged = abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1
        guard sizeChanged else { return }

        // Matches PR #6: when not yet shown, record the size so fittingSize
        // pre-sizing in finishOpenPanel() opens at the correct dimensions.
        // ❌ NEVER early-return here without recording — the size would be
        //    dropped and the popover would open frozen at its initial size.
        guard panelIsOpen else {
            log("AppDelegate › resizeAndRepositionPanel — not open yet, recording contentSize newW=\(newW) newH=\(newH)")
            popover.contentSize = NSSize(width: newW, height: newH)
            return
        }

        guard let window = popover.contentViewController?.view.window else {
            log("AppDelegate › resizeAndRepositionPanel — no window, setting contentSize only newW=\(newW) newH=\(newH)")
            popover.contentSize = NSSize(width: newW, height: newH)
            return
        }
        let oldFrame = window.frame
        let dw = newW - currentSize.width
        let dh = newH - currentSize.height
        log("AppDelegate › resizeAndRepositionPanel — oldFrame=\(oldFrame) currentSize=\(currentSize) " +
            "newW=\(newW) newH=\(newH) dw=\(dw) dh=\(dh)")
        let screenVisibleOriginX = statusItemScreen.visibleFrame.origin.x
        let oldFrameLooksDegenerate = oldFrame.width <= 0 || oldFrame.height <= 0
            || (oldFrame.origin.x == 0 && screenVisibleOriginX != 0)
        if oldFrameLooksDegenerate {
            log("AppDelegate › resizeAndRepositionPanel — WARNING: oldFrame looks degenerate " +
                "(oldFrame=\(oldFrame) screenVisibleOriginX=\(screenVisibleOriginX)), " +
                "applying contentSize WITHOUT origin correction")
            popover.contentSize = NSSize(width: newW, height: newH)
            return
        }
        popover.contentSize = NSSize(width: newW, height: newH)
        var newOrigin = oldFrame.origin
        newOrigin.x -= dw / 2
        newOrigin.y -= dh
        log("AppDelegate › resizeAndRepositionPanel — newOrigin=\(newOrigin)")
        window.setFrameOrigin(newOrigin)
    }

    // MARK: - Navigation

    /// Swaps the content slot in the permanent NavigationShell.
    ///
    /// Wraps `view` with a background GeometryReader via `wrapWithSizeReporter(_:)`
    /// BEFORE storing as AnyView — matching PR #6's pendingRootView wrapping.
    /// The GeometryReader is therefore inside the AnyView boundary and fires on
    /// every layout pass, including async @Observable state changes inside the view.
    ///
    /// Increments `navigationShell.navigationID` BEFORE writing content so
    /// NavigationShellView's `.id(navigationID)` forces a full destroy/recreate,
    /// guaranteeing `onAppear` fires with the new content's intrinsic size.
    ///
    /// ❌ NEVER set hostingController.rootView here — that tears down the shell.
    /// ❌ NEVER call this from a SwiftUI view — use callbacks only.
    func navigate(to view: AnyView) {
        navigationShell?.navigationID += 1
        navigationShell?.content = wrapWithSizeReporter(view)
    }

    // MARK: - Make key for text input

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
        lifecycleCoordinator.tearDown()
        panelVisibilityState.isOpen = false
    }

    /// Closes the popover explicitly (Escape / back navigation / manual close).
    /// Resets content to main so next open starts fresh.
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
        // Reset to main so the next open starts fresh.
        // ❌ Do NOT do this in hidePanel() — it destroys sheet @State.
        navigationShell?.content = wrapWithSizeReporter(mainView())
    }

    /// Hides the popover on outside-tap or workspace app-switch.
    /// ❌ NEVER reset navigationShell.content here — sheet @State must survive.
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

    func makePopoverWindowKeyIfPossible() {
        guard let popoverWindow = popover?.contentViewController?.view.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        popoverWindow.makeKey()
    }

    // MARK: - Toggle

    @objc func togglePanel() {
        if panelIsOpen { closePanel() } else { openPanel() }
    }

    // MARK: - Open

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
            showRetryCount = 0
            lastObservedButtonFrame = nil
            showPopoverRetryingIfNeeded(button: button, popover: popover)
        } else {
            finishOpenPanel()
        }
    }

    private func positioningRect(for button: NSStatusBarButton) -> NSRect? {
        let bounds = button.bounds
        guard bounds.width > 0, bounds.height > 0 else {
            log("AppDelegate › positioningRect — skipped: button.bounds is degenerate \(bounds)")
            return nil
        }
        return NSRect(x: bounds.midX - 0.5, y: bounds.minY, width: 1, height: bounds.height)
    }

    private func showPopoverRetryingIfNeeded(button: NSStatusBarButton, popover: NSPopover) {
        let buttonFrame = button.window?.frame ?? .zero
        let frameLooksValid = buttonFrame.width > 0 && buttonFrame.height > 0
            && NSScreen.screens.contains { $0.frame.intersects(buttonFrame) }
        let frameSettled = frameLooksValid && lastObservedButtonFrame == buttonFrame
        guard let rect = (frameSettled || showRetryCount >= Self.maxShowRetries)
            ? positioningRect(for: button) : nil else {
            showRetryCount += 1
            lastObservedButtonFrame = frameLooksValid ? buttonFrame : nil
            log("AppDelegate › showPopoverRetryingIfNeeded — button frame not yet settled or bounds degenerate " +
                "(\(buttonFrame), validNow=\(frameLooksValid)), retry \(showRetryCount)/\(Self.maxShowRetries)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showPopoverRetryingIfNeeded(button: button, popover: popover)
            }
            return
        }
        log("AppDelegate › openPanel — PRE-SHOW behavior=\(popover.behavior.rawValue) " +
            "delegate=\(String(describing: popover.delegate)) buttonFrame=\(buttonFrame) positioningRect=\(rect)")
        popover.show(relativeTo: rect, of: button, preferredEdge: .minY)
        log("AppDelegate › openPanel — POST-SHOW behavior=\(popover.behavior.rawValue)")
        finishOpenPanel()
    }

    private func finishOpenPanel() {
        makePopoverWindowKeyIfPossible()
        if let controller = hostingController {
            let fitting = controller.view.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                resizeAndRepositionPanel(preferredSize: fitting)
            }
        }
        if let saved = appState.savedNavState, !hasActiveSheet, let restored = validatedView(for: saved) {
            navigate(to: restored)
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
