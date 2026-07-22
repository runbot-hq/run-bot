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
// 3. Size is driven by KVO on NSHostingController.preferredContentSize.
//    Both width AND height are updated via popover.contentSize.
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
// LATERAL JUMP PREVENTION — delta-based fix (matches runbot-hq/MenuBarKit #12 / PR #6):
//
// NSPopover only centers its window around the positioningRect ONCE, at
// show() time. After that, mutating contentSize alone causes AppKit to grow
// the window from its bottom-left corner — nothing re-runs the centering
// math, so the arrow stays pinned while the box drifts away from it.
//
// FOUR FAILED APPROACHES (see runbot-hq/MenuBarKit issue #12 for the full
// writeup — this file's history repeated each of these before landing here):
//   1. No correction at all — box visibly drifts/snaps away from the arrow.
//   2. `window.frame.midX` as anchor, offset by `contentSize/2` — WRONG:
//      `window.frame` includes NSPopover chrome (shadow/border/arrow chrome)
//      but `contentSize` does not. Mixing the two coordinate spaces produces
//      a systematic offset (observed: window snapped to x=0 near a screen edge).
//   3. Re-querying `button.window.frame` / button screen position on every
//      resize — WRONG: button screen coordinates are NOT stable across
//      sessions. macOS auto-hide slides the whole status bar off/on screen,
//      changing button screen-Y between open/close cycles.
//   4. Reading `window.frame` for the correction AFTER writing `contentSize`
//      — WRONG: AppKit repositions the window as a side-effect of the
//      `contentSize` write, so frame is already stale by the time it's read.
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
// ⚠️ INSTRUMENTATION + DEGENERATE-BASELINE GUARD (this revision):
// resizeAndRepositionPanel() previously had ZERO logging, so a sidejump that
// happens WHILE the panel is already open (content grows as data streams in,
// e.g. workflow rows populating after open) was invisible in log dumps —
// every prior fix attempt was debugging the open-time anchor path
// (showPopoverRetryingIfNeeded) because that was the only instrumented one.
// Every call now logs oldFrame / dw / dh / newOrigin. Additionally, if the
// `oldFrame` read at the top of the function is degenerate — zero width or
// height, or origin.x == 0 while the status item's screen visibleFrame does
// NOT start at x == 0 — the delta shift is skipped and a warning is logged
// instead of propagating a bad baseline into window.setFrameOrigin(). This
// does not replace the delta math above; it guards it and makes the next
// repro observable instead of another blind theory.
//
// AUTOHIDE SIDE-JUMP AT OPEN TIME (separate issue from the above — NOT
// covered by MenuBarKit PR #6, which only addresses resize/reposition):
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

    /// Number of `showPopoverRetryingIfNeeded()` retries attempted for the current open.
    /// Reset to 0 at the start of every `openPanel()` call.
    private var showRetryCount = 0
    /// Hard cap on retries so a persistently invalid button frame can never hang
    /// the open path or loop forever — falls back to showing immediately.
    private static let maxShowRetries = 10
    /// The button frame observed on the PREVIOUS `showPopoverRetryingIfNeeded()`
    /// tick, used to confirm the frame has settled (identical two ticks in a row)
    /// rather than trusting a single non-zero sample taken mid-slide-in.
    /// Reset to nil at the start of every `openPanel()` call.
    private var lastObservedButtonFrame: NSRect?

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

    /// Clamps the popover's `contentSize` to the current screen bounds, then
    /// corrects the window origin using a DELTA-based shift (never absolute
    /// button/screen coordinates — see the "LATERAL JUMP PREVENTION" note at
    /// the top of this file, and runbot-hq/MenuBarKit issue #12).
    ///
    /// ⚠️ Every branch of this function is logged (see "INSTRUMENTATION +
    /// DEGENERATE-BASELINE GUARD" note at the top of this file). Do not strip
    /// the logging in a future cleanup pass without checking whether the
    /// mid-session sidejump has actually been closed out — it was invisible
    /// for multiple debugging rounds specifically because this function was
    /// silent.
    func resizeAndRepositionPanel() {
        guard panelIsOpen, let popover, let controller = hostingController else { return }
        let preferred = controller.preferredContentSize
        guard preferred.height > 0 else { return }
        let newW = min(max(preferred.width > 0 ? preferred.width : Self.minWidth, Self.minWidth), maxWidth)
        let newH = min(max(preferred.height, 60), maxHeight)
        let currentSize = popover.contentSize
        let sizeChanged = abs(currentSize.width - newW) > 1 || abs(currentSize.height - newH) > 1
        guard sizeChanged else { return }
        guard let window = popover.contentViewController?.view.window else {
            log("AppDelegate › resizeAndRepositionPanel — no window, setting contentSize only newW=\(newW) newH=\(newH)")
            popover.contentSize = NSSize(width: newW, height: newH)
            return
        }
        // Read the frame BEFORE mutating contentSize — AppKit repositions the
        // window as a side-effect of the contentSize write, so reading after
        // would give a frame already shifted by AppKit's own bottom-left growth.
        let oldFrame = window.frame
        let dw = newW - currentSize.width
        let dh = newH - currentSize.height
        log("AppDelegate › resizeAndRepositionPanel — oldFrame=\(oldFrame) currentSize=\(currentSize) " +
            "newW=\(newW) newH=\(newH) dw=\(dw) dh=\(dh)")
        // Degenerate-baseline guard: if oldFrame is zero-sized, or its origin.x
        // is 0 while the status item's screen does NOT start at x == 0, the
        // frame we just read is not a trustworthy baseline for the delta shift
        // (see "INSTRUMENTATION + DEGENERATE-BASELINE GUARD" note above). Skip
        // the origin correction rather than propagate a bad baseline — the
        // window still resizes via contentSize below, just without the
        // (currently unreliable) position correction for this one call.
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
        // Shift the EXISTING origin by the delta — never recompute an absolute
        // target from button/screen coordinates (see doc comment above).
        var newOrigin = oldFrame.origin
        newOrigin.x -= dw / 2   // grow symmetrically → midX stays fixed
        newOrigin.y -= dh       // grow downward only → maxY (top/arrow edge) stays fixed
        log("AppDelegate › resizeAndRepositionPanel — newOrigin=\(newOrigin)")
        window.setFrameOrigin(newOrigin)
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
            showRetryCount = 0
            lastObservedButtonFrame = nil
            showPopoverRetryingIfNeeded(button: button, popover: popover)
        } else {
            finishOpenPanel()
        }
    }

    /// Shows `popover` relative to `button`, retrying on the next run-loop turn if the
    /// button's backing window does not yet have a valid, SETTLED on-screen frame.
    ///
    /// AUTOHIDE FIX: with menu bar auto-hide enabled, the click that triggers
    /// `togglePanel()` is often the SAME click that reveals the menu bar. AppKit may
    /// not have finished laying out the revealed status item at that instant, so
    /// `button.window`'s frame can still be zero/off-screen, OR — the case a single
    /// non-zero sample missed — mid-slide-in with a frame that is non-zero and
    /// on-screen but NOT YET FINAL. Calling `popover.show()` against that
    /// transitional geometry anchors the popover at the wrong location; the menu
    /// bar then finishes revealing, the button's real resting frame shifts, and
    /// the already-shown popover does not follow — producing a visible sidejump.
    ///
    /// Fix: require the frame to be IDENTICAL across two consecutive run-loop
    /// ticks (settled) before accepting it, not just non-zero/on-screen once.
    /// Deferred via `DispatchQueue.main.async`, capped at `Self.maxShowRetries`
    /// attempts, after which it falls back to showing with whatever frame is
    /// available so the open path can never hang indefinitely.
    private func showPopoverRetryingIfNeeded(button: NSStatusBarButton, popover: NSPopover) {
        let buttonFrame = button.window?.frame ?? .zero
        let frameLooksValid = buttonFrame.width > 0 && buttonFrame.height > 0
            && NSScreen.screens.contains { $0.frame.intersects(buttonFrame) }
        let frameSettled = frameLooksValid && lastObservedButtonFrame == buttonFrame
        guard frameSettled || showRetryCount >= Self.maxShowRetries else {
            showRetryCount += 1
            lastObservedButtonFrame = frameLooksValid ? buttonFrame : nil
            log("AppDelegate › showPopoverRetryingIfNeeded — button frame not yet settled " +
                "(\(buttonFrame), validNow=\(frameLooksValid)), retry \(showRetryCount)/\(Self.maxShowRetries)")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showPopoverRetryingIfNeeded(button: button, popover: popover)
            }
            return
        }
        log("AppDelegate › openPanel — PRE-SHOW behavior=\(popover.behavior.rawValue) " +
            "delegate=\(String(describing: popover.delegate)) buttonFrame=\(buttonFrame)")
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        log("AppDelegate › openPanel — POST-SHOW behavior=\(popover.behavior.rawValue)")
        finishOpenPanel()
    }

    /// Completes the open sequence after `popover.show()` (or the preserved-window
    /// restore path) has run: activates the key window, resizes to fit content,
    /// restores saved navigation state, and installs the outside-click / app-switch
    /// monitors.
    private func finishOpenPanel() {
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
