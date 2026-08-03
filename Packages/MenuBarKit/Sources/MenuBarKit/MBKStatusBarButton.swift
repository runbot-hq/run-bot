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
// WHY TWO OVERRIDES ARE NEEDED:
//   highlight(_:) on NSButton is the public API path.
//   highlight(_:withFrame:inView:) on NSButtonCell is the internal path
//   AppKit calls directly — it bypasses the NSButton override entirely.
//   Both must be guarded, confirmed by diagnostic logs showing castOK=true
//   and isPanelOpen flipping correctly while the button was still clearing.
//   See #2440.

import AppKit

// MARK: - Cell

/// `NSButtonCell` subclass that guards the internal cell-level highlight
/// path AppKit calls directly, bypassing `NSButton.highlight(_:)`.
///
/// Injected onto the button's existing cell via `object_setClass` inside
/// `MBKStatusBarButton.injectCellSubclass()`. `NSButtonCell` has no extra
/// stored ivars beyond `NSCell`, so the swap carries no ivar-layout risk.
final class MBKStatusBarButtonCell: NSButtonCell {

    /// Weak reference back to the owning button so the cell can read `isPanelOpen`
    /// without creating a retain cycle.
    weak var button: MBKStatusBarButton?

    /// AppKit calls this directly on the cell when tracking mouse events and
    /// during key-window transitions — it never goes through `NSButton.highlight(_:)`.
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        if !flag, let btn = button, btn.isPanelOpen { return }
        super.highlight(flag, withFrame: cellFrame, in: controlView)
    }
}

// MARK: - Button

/// `NSStatusBarButton` subclass that suppresses AppKit-internal
/// `highlight(false)` calls while the panel is open.
///
/// Guards two call paths:
/// 1. `NSButton.highlight(_:)` — the public API path.
/// 2. `NSButtonCell.highlight(_:withFrame:inView:)` — the internal path
///    AppKit uses directly during mouse tracking and key-window transitions.
///
/// Both are required. Logs confirmed the button-level guard was working
/// (castOK=true, isPanelOpen flipping) while the cell path remained unguarded.
/// See #2440.
final class MBKStatusBarButton: NSStatusBarButton {

    /// Set to `true` while the panel is open.
    /// Guards both the button-level and cell-level highlight paths.
    var isPanelOpen = false

    // MARK: - Cell injection

    /// Injects `MBKStatusBarButtonCell` onto the button's existing cell.
    /// Must be called once after `object_setClass` swaps the button's own isa.
    /// Safe: `NSButtonCell` has no extra stored ivars, so no ivar-layout mismatch.
    func injectCellSubclass() {
        guard let cell = self.cell else {
            return
        }
        object_setClass(cell, MBKStatusBarButtonCell.self)
        (cell as? MBKStatusBarButtonCell)?.button = self
    }

    // MARK: - Button-level guard

    override func highlight(_ flag: Bool) {
        // Guard the public NSButton path.
        // teardown() sets isPanelOpen = false BEFORE calling highlight(false),
        // so the close path always goes through to super.
        if !flag && isPanelOpen { return }
        super.highlight(flag)
    }
}
