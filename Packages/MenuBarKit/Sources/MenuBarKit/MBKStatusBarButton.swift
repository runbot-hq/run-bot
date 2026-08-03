// MBKStatusBarButton.swift
// MenuBarKit
//
// NSStatusBarButton subclass that guards highlight(false) calls while
// the panel is open. Injected via object_setClass after status item
// creation — NSStatusBarButton cannot be directly instantiated.
//
// Safety: NSStatusBarButton has no extra stored ivars (thin subclass of
// NSButton), so object_setClass carries no ivar-layout mismatch risk.
// The override only adds behaviour; it does not change the memory layout.
//
// WHY NOT a notification or DispatchQueue.main.async re-assertion:
// Both fire after AppKit has already cleared the highlight AND after
// the frame has been committed to the display — producing a visible
// single-frame flash. This subclass intercepts highlight(false) before
// it reaches the cell, so nothing ever reaches the screen. See #2440.

import AppKit

/// `NSStatusBarButton` subclass that suppresses AppKit-internal
/// `highlight(false)` calls while the panel is open.
///
/// AppKit calls `highlight(false)` unconditionally in at least three places:
/// - `mouseUp` end of button tracking (addressed by `sendAction(on:)` in #2428)
/// - `panel.makeKey()` key-window transition on the status bar window
/// - App-switch (`NSWorkspace` active-app change)
///
/// Setting `isPanelOpen = true` before opening the panel and
/// `isPanelOpen = false` before calling `highlight(false)` on close
/// ensures the button stays pressed for the full panel session.
final class MBKStatusBarButton: NSStatusBarButton {

    /// Set to `true` while the panel is open.
    /// Guards against AppKit-internal `highlight(false)` calls.
    var isPanelOpen = false {
        didSet {
            mbkLog("MBKStatusBarButton", "isPanelOpen changed \(oldValue) → \(isPanelOpen)")
        }
    }

    override func highlight(_ flag: Bool) {
        // Print the call stack so we can identify which AppKit frame is
        // calling highlight(false) — key diagnostic for #2440.
        let caller = Thread.callStackSymbols.prefix(8).joined(separator: "\n    ")
        if !flag && isPanelOpen {
            mbkLog("MBKStatusBarButton",
                "🛡 highlight(false) SWALLOWED (isPanelOpen=true)\n    \(caller)")
            return
        }
        mbkLog("MBKStatusBarButton",
            "highlight(\(flag)) → super  isPanelOpen=\(isPanelOpen)\n    \(caller)")
        super.highlight(flag)
    }
}
