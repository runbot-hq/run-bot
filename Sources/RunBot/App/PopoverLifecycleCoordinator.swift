// PopoverLifecycleCoordinator.swift
// RunBot
//
// Extracted from AppDelegate as part of #1374.
// Owns the four lifecycle concerns that AppDelegate previously stored directly:
//   • panelIsOpen flag
//   • preservedSheetWindowHide flag
//   • outsideClickMonitor (global NSEvent monitor)
//   • workspaceObserver (NSWorkspace app-switch notification)
//
// AppDelegate retains NSPopover and NSStatusItem — they have broader scope
// and are passed at call-time rather than stored here, keeping the
// dependency surface explicit and avoiding a back-reference to AppDelegate.
//
// ⚠️ All methods must be called on the main actor.

import AppKit
import RunBotCore

/// Owns the four popover lifecycle concerns extracted from `AppDelegate`:
/// panel-open flag, preserved-sheet-window flag, outside-click monitor, and
/// workspace app-switch observer. All methods must be called on the main actor.
@MainActor
final class PopoverLifecycleCoordinator {

    // MARK: - State

    /// Mirrors `popover.isShown`. Source of truth for panel visibility.
    /// Set by `setPanelIsOpen(_:)`, cleared by `tearDown()`.
    private(set) var panelIsOpen: Bool = false

    /// Set to `true` by `hidePopoverWindowsPreservingSheets()` when the popover
    /// window is hidden without closing so the sheet NSWindow survives.
    /// ❌ NEVER read outside the three methods that manage it.
    private(set) var preservedSheetWindowHide: Bool = false

    /// Set to `true` for one runloop turn by `suppressHidePanel()` when a
    /// SwiftUI sheet is being intentionally dismissed by the user (e.g. Cancel /
    /// Save inside RunnerDetailSheet). Prevents the outside-click monitor and
    /// workspace observer from firing `hidePanel` during the brief window between
    /// the user's tap and the sheet NSWindow being fully detached.
    ///
    /// The monitors do **not** read this flag directly. They read it indirectly
    /// via the `hasActiveSheet` closure injected by the caller in
    /// `installMonitors(hasActiveSheet:popoverWindow:onHide:)`. It is the
    /// **caller's responsibility** to incorporate `isSheetDismissing` into that
    /// closure (e.g. `{ self.isSheetDismissing || self.popover.isSheetPresented }`).
    /// If `hasActiveSheet` does not account for `isSheetDismissing`, the
    /// suppression is silently ineffective.
    ///
    /// ❌ NEVER set this from anything other than `suppressHidePanel()`.
    private(set) var isSheetDismissing: Bool = false

    // MARK: - Private monitor storage

    /// Global NSEvent monitor installed by `installMonitors(…)`.
    /// Removed by `tearDown()`.
    ///
    /// `nonisolated(unsafe)`: required so `deinit` (which is nonisolated per SE-0327)
    /// can release the monitor without a data-race warning. Every live read/write
    /// is `@MainActor`-guarded; `deinit` runs only after the last strong reference
    /// drops (app teardown), so no concurrent access is possible in practice.
    nonisolated(unsafe) private var outsideClickMonitor: Any?

    /// NSWorkspace observer installed by `installMonitors(…)`.
    /// Removed by `tearDown()`.
    ///
    /// `nonisolated(unsafe)`: same rationale as `outsideClickMonitor` above.
    nonisolated(unsafe) private var workspaceObserver: NSObjectProtocol?

    // MARK: - Mutators

    /// Updates `panelIsOpen`. Call this whenever the popover is shown or hidden.
    func setPanelIsOpen(_ value: Bool) {
        panelIsOpen = value
    }

    /// Updates `preservedSheetWindowHide`. Set to `true` when the popover window
    /// is hidden without closing so the sheet `NSWindow` survives the transition.
    func setPreservedSheetWindowHide(_ value: Bool) {
        preservedSheetWindowHide = value
    }

    /// Suppresses `hidePanel` for one runloop turn.
    ///
    /// Call this immediately **before** setting a `.sheet(item:)` binding to `nil`
    /// from an intentional user dismiss (Cancel / Save in a sheet). Both the
    /// outside-click monitor and the workspace observer check `isSheetDismissing`
    /// indirectly via the `hasActiveSheet` closure — see `isSheetDismissing` for
    /// the indirection contract.
    ///
    /// The flag self-clears via a `Task { @MainActor }` enqueued on the same
    /// runloop turn, which runs after all synchronous SwiftUI state propagation
    /// and AppKit sheet-detach work has completed.
    ///
    /// TASK ORDERING NOTE: `Task { @MainActor }` schedules a Swift concurrency
    /// task, not a runloop observer. The one-turn clear is reliable from
    /// synchronous call sites because the enqueued Task runs after the current
    /// synchronous call stack unwinds. However, Task ordering relative to AppKit's
    /// own sheet-detach callbacks is informal — not guaranteed by the Swift
    /// runtime spec. A `DispatchQueue.main.asyncAfter(deadline: .now())` or
    /// `RunLoop.main` observer would give a formally guaranteed one-turn delay.
    /// This is acceptable for the current synchronous call sites; re-evaluate
    /// before adding async call sites or if AppKit callback ordering changes.
    ///
    /// **Synchronous call sites only.** The one-turn clear contract holds because
    /// the enqueued `Task` runs after the current synchronous work drains. If a
    /// call site introduces an `await` between `suppressHidePanel()` and the
    /// binding mutation, the flag will have already cleared before the sheet
    /// teardown begins and the suppression will silently do nothing. Re-verify
    /// the timing contract at every call site when porting this to the main app.
    ///
    /// ❌ NEVER set `isSheetDismissing` directly — use this method only.
    ///
    /// NO CALL SITE ON THIS BRANCH — INTENTIONAL:
    /// `suppressHidePanel()` is forward-looking infrastructure introduced alongside
    /// the `isSheetDismissing` flag so the `hasActiveSheet` closure in `AppDelegate
    /// .openPanel()` is already correct when the call site lands. The call site
    /// belongs in `LocalRunnersView` (onCancel / onCommit success paths, immediately
    /// before `editingRunner = nil`) and will be wired in the migration PR that ports
    /// the main app to `MBKAnchoredSheet`. Periphery will report this as dead code
    /// on this branch — that is expected and not a bug.
    // periphery:ignore - intentionally uncalled; call site lands in the migration PR (see doc comment above)
    func suppressHidePanel() {
        guard !isSheetDismissing else { return }
        isSheetDismissing = true
        log("PopoverLifecycleCoordinator › suppressHidePanel — isSheetDismissing=true")
        Task { @MainActor [weak self] in
            self?.isSheetDismissing = false
            log("PopoverLifecycleCoordinator › suppressHidePanel — isSheetDismissing cleared")
        }
    }

    // MARK: - Monitor lifecycle

    /// Installs the outside-click monitor and app-switch observer.
    ///
    /// - Parameters:
    ///   - hasActiveSheet: Closure returning whether a sheet (or any overlay) is
    ///     currently active. The monitors skip `hidePanel` while this returns `true`.
    ///     **The caller must incorporate `isSheetDismissing` into this closure**
    ///     for `suppressHidePanel()` to have any effect — the coordinator does not
    ///     read `isSheetDismissing` inside the monitors directly. A typical
    ///     implementation: `{ self.lifecycleCoordinator.isSheetDismissing || self.popover.isSheetPresented }`
    ///   - popoverWindow: Closure returning the live NSPopover backing window,
    ///     used to hit-test outside clicks.
    ///   - onHide: Called on the main actor when the monitor decides the popover
    ///     should be hidden. Typically `AppDelegate.hidePanel`.
    func installMonitors(
        hasActiveSheet: @escaping @MainActor () -> Bool,
        popoverWindow: @escaping @MainActor () -> NSWindow?,
        onHide: @escaping @MainActor () -> Void
    ) {
        // Guard against double-installation: remove any previously installed
        // monitors before installing new ones so nothing leaks on re-entrant calls.
        // ⚠️ Must NOT call tearDown() here — tearDown() also resets panelIsOpen,
        // but openPanel() has already called setPanelIsOpen(true) before reaching
        // this point. Calling tearDown() would clear the flag, causing both the
        // outside-click and workspace monitors to immediately fail their
        // `guard self.panelIsOpen` check and never dismiss the popover.
        if outsideClickMonitor != nil || workspaceObserver != nil {
            log("PopoverLifecycleCoordinator › installMonitors — WARNING: called with active monitors, removing stale monitors first")
            removeMonitors()
        }

        // Outside-click monitor.
        // Fires on every left/right click outside the popover.
        // tearDown() removes it on every close path.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let screenLoc = event.window?.convertToScreen(
                NSRect(origin: event.locationInWindow, size: .zero)
            ).origin ?? NSEvent.mouseLocation
            log("PopoverLifecycleCoordinator › outsideClickMonitor — FIRED type=\(event.type.rawValue) screenLoc=\(screenLoc)")
            Task { @MainActor [weak self] in
                guard let self else {
                    log("PopoverLifecycleCoordinator › outsideClickMonitor — self is nil, skipping")
                    return
                }
                log("PopoverLifecycleCoordinator › outsideClickMonitor — panelIsOpen=\(self.panelIsOpen)")
                guard self.panelIsOpen else {
                    log("PopoverLifecycleCoordinator › outsideClickMonitor — guard exit: panel not open")
                    return
                }
                guard !hasActiveSheet() else {
                    // hasActiveSheet() is the caller-injected closure that must
                    // incorporate isSheetDismissing — see installMonitors parameter docs.
                    log("PopoverLifecycleCoordinator › outsideClickMonitor — guard exit: hasActiveSheet=true, skipping hidePanel")
                    return
                }
                guard let window = popoverWindow() else {
                    log("PopoverLifecycleCoordinator › outsideClickMonitor — WARNING: popoverWindow is nil, skipping hidePanel")
                    return
                }
                log("PopoverLifecycleCoordinator › outsideClickMonitor — popoverFrame=\(window.frame) screenLoc=\(screenLoc) contains=\(window.frame.contains(screenLoc))")
                if window.frame.contains(screenLoc) {
                    log("PopoverLifecycleCoordinator › outsideClickMonitor — click inside popover window, ignoring")
                    return
                }
                log("PopoverLifecycleCoordinator › outsideClickMonitor — calling onHide() screenLoc=\(screenLoc)")
                onHide()
            }
        }
        log("PopoverLifecycleCoordinator › installMonitors — outsideClickMonitor installed: \(String(describing: outsideClickMonitor))")

        // App-switch observer.
        //
        // IMPORTANT — self-activation guard below is intentional:
        // Prevents the popover from self-dismissing when RunBot regains focus
        // after an NSOpenPanel picker closes (the picker re-activates its parent
        // app, which would otherwise trigger onHide on the way back in).
        // ❌ Do NOT remove the `activatedApp != NSRunningApplication.current` guard.
        // NOTE: the `hasActiveSheet` closure itself captures `[weak self]` from
        // AppDelegate, so there is a double-weak chain:
        //   coordinator (weak) → AppDelegate (weak) → popover
        // This is intentional and safe. If AppDelegate is deallocated while the
        // observer is still installed (shouldn't happen in normal lifetime, but
        // guards against future scope changes), `hasActiveSheet` returns false
        // and `onHide` is a no-op — no crash, no leak.
        //
        // `queue: .main` delivers this closure on the main queue, so we are
        // already on the main actor — no Task hop needed. The body accesses
        // @MainActor-isolated state (`panelIsOpen`) and calls @MainActor
        // closures (`hasActiveSheet`, `onHide`) directly.
        //
        // ASYMMETRY WITH MBKPopoverController:
        // MBKPopoverController uses queue: nil + Task { @MainActor }, which is
        // strictly Swift 6-correct (compiler-enforced isolation). This file uses
        // queue: .main + MainActor.assumeIsolated, which is a runtime assertion.
        // Both are safe in practice; the spike uses the stricter pattern.
        // This coordinator should be updated to match when time permits.
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication else {
                log("PopoverLifecycleCoordinator › workspaceObserver — FIRED but activatedApp is nil, skipping")
                return
            }
            let appName = activatedApp.localizedName ?? "unknown"
            log("PopoverLifecycleCoordinator › workspaceObserver — FIRED activated=\(appName)")
            guard activatedApp != NSRunningApplication.current else {
                log("PopoverLifecycleCoordinator › workspaceObserver — guard exit: RunBot self-activated, skipping hidePanel")
                return
            }
            // Already on main queue (queue: .main above) — access actor state directly.
            // NB: intentional asymmetry with the outsideClickMonitor closure, which uses
            // a Task { @MainActor } hop. NSNotificationCenter delivers on queue: .main here
            // (see `queue: .main` in addObserver above), so assumeIsolated is safe and
            // avoids the async scheduling overhead. The outside-click path uses a global
            // NSEvent monitor whose callback thread is unspecified, hence the Task hop.
            // ⚠️ If NSNotificationCenter ever changes delivery guarantees, replace with
            // Task { @MainActor [weak self] in … } to match the outside-click path.
            MainActor.assumeIsolated {
                guard let self else {
                    log("PopoverLifecycleCoordinator › workspaceObserver — self is nil, skipping")
                    return
                }
                log("PopoverLifecycleCoordinator › workspaceObserver — panelIsOpen=\(self.panelIsOpen)")
                guard self.panelIsOpen else {
                    log("PopoverLifecycleCoordinator › workspaceObserver — guard exit: panel not open")
                    return
                }
                guard !hasActiveSheet() else {
                    // hasActiveSheet() is the caller-injected closure that must
                    // incorporate isSheetDismissing — see installMonitors parameter docs.
                    log("PopoverLifecycleCoordinator › workspaceObserver — guard exit: hasActiveSheet=true, skipping hidePanel")
                    return
                }
                log("PopoverLifecycleCoordinator › workspaceObserver — calling onHide() because activated=\(appName)")
                onHide()
            }
        }
        log("PopoverLifecycleCoordinator › installMonitors — workspaceObserver installed")
    }

    // MARK: - Teardown

    /// Removes all installed monitors and clears `panelIsOpen` and `isSheetDismissing`.
    ///
    /// `isSheetDismissing` is reset here to guard against a specific race: if
    /// `suppressHidePanel()` is called and the user then closes the popover via a
    /// system gesture before the self-clearing `Task` fires, `isSheetDismissing`
    /// would stay `true` into the next open. On the next open, any outside-click
    /// whose `hasActiveSheet` closure incorporates `isSheetDismissing` would be
    /// silently swallowed. Resetting here ensures teardown is always a clean slate.
    ///
    /// Does **not** touch `preservedSheetWindowHide` — that flag is exclusively
    /// managed by `hidePopoverWindowsPreservingSheets()` and
    /// `restorePopoverWindowsPreservingSheetsIfNeeded()`. Resetting it here
    /// would orphan a temporarily hidden popover window on the outside-click /
    /// app-switch close paths.
    /// Must be called on every close path (explicit close, outside-click, app-switch).
    func tearDown() {
        panelIsOpen = false
        isSheetDismissing = false
        removeMonitors()
    }

    /// Removes the outside-click monitor and workspace observer without touching
    /// any state flags. Used by the double-install guard in `installMonitors()`
    /// so that stale monitors are cleaned up without clobbering `panelIsOpen`.
    private func removeMonitors() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
            log("PopoverLifecycleCoordinator › removeMonitors — outsideClickMonitor removed")
        } else {
            log("PopoverLifecycleCoordinator › removeMonitors — outsideClickMonitor was already nil")
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            workspaceObserver = nil
            log("PopoverLifecycleCoordinator › removeMonitors — workspaceObserver removed")
        } else {
            log("PopoverLifecycleCoordinator › removeMonitors — workspaceObserver was already nil")
        }
    }

    // MARK: - Deallocation

    /// Defensive cleanup: removes any installed monitors if the coordinator is
    /// deallocated without an explicit `tearDown()` call. In normal app lifetime
    /// `lifecycleCoordinator` is `let` on `AppDelegate` and is never released,
    /// so this path is never taken — but guards against a future shorter-lived owner.
    deinit {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
