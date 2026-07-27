// PanelVisibilityState.swift
// RunBotCore
import CoreGraphics
import Observation

// ════════════════════════════════════════════════════════════════════════════════
// ⚠️ PanelVisibilityState — SIDE-JUMP REGRESSION GUARD (ref #377 #375 #376)
// ════════════════════════════════════════════════════════════════════════════════
//
// PURPOSE:
// 1. Provides a live, mutable signal of whether the NSPanel is currently open.
//
// WHY NOT A PLAIN Bool PROP:
// AppDelegate constructs PanelMainView (via mainView()) BEFORE the panel
// opens. Any plain `var isPanelOpen: Bool` prop is therefore always `false`
// at the point InlineJobRowsView evaluates it. This @Observable object is
// mutated by AppDelegate immediately before NSPanel.show() and after
// NSPanel.close(), so the value seen inside the view is always live.
//
// ⚠️ CONTRACT:
// ❌ NEVER replace isOpen with a plain Bool prop on any view.
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.
// ════════════════════════════════════════════════════════════════════════════════

/// Observable wrapper for NSPanel open/closed state.
/// - Note: `@MainActor` enforces the main-thread constraint that was previously
///   only documented. All mutation sites (AppDelegate, SwiftUI view callbacks)
///   are already main-actor contexts, so this is a no-op at runtime but lets
///   the compiler verify the invariant under Swift 6 strict concurrency.
@MainActor
@Observable
public final class PanelVisibilityState {
    /// `true` from immediately before the panel opens until after it closes.
    public var isOpen: Bool = false

    /// Set to `true` by `hidePanel()` BEFORE it sets `isOpen = false`.
    /// Set back to `false` by `PanelContainerView.onChange` when `isOpen` becomes `true` again.
    ///
    /// PURPOSE — prevent the dim-overlay animation from replaying on transient restore:
    /// When the user switches away from the app while a sheet is open, hidePanel() fires.
    /// hidePanel() does NOT dismiss the sheet — the sheet NSWindow stays attached.
    /// But it does set isOpen = false, which fires onChange in PanelContainerView.
    /// Without this flag, onChange(false) would clear isSheetActive, and then on
    /// re-entry the timer would set it back to true, replaying the fade-in animation
    /// even though the sheet never actually closed. With this flag, onChange(false)
    /// and the timer guard both skip the clear, keeping isSheetActive = true throughout
    /// the hide/restore cycle so no animation fires.
    ///
    /// LIFECYCLE:
    ///   hidePanel()              → isTransientHide = true, isOpen = false
    ///   openPanel() (restore)    → isOpen = true
    ///   onChange(true) in view   → isTransientHide = false  (reset for next close)
    ///   closePanel()             → isTransientHide stays false, isOpen = false
    ///   onChange(false) in view  → isTransientHide=false so isSheetActive cleared ✅
    ///
    /// SET BY:   AppDelegate.hidePanel() (sets true) — see AppDelegate.swift
    /// RESET BY: PanelContainerView.onChange(isOpen) open=true branch (sets false)
    ///
    /// ❌ NEVER set this from anywhere other than hidePanel().
    /// ❌ NEVER reset this from anywhere other than the open branch of onChange in PanelContainerView.
    /// ❌ NEVER read this outside PanelContainerView — it is an internal signal
    ///    between hidePanel() and the dim-overlay state machine.
    /// ❌ NEVER set isOpen = false in hidePanel() before setting this to true —
    ///    the flag must be visible to onChange before isOpen triggers it.
    public var isTransientHide: Bool = false

    /// Creates a new `PanelVisibilityState` with all flags in their initial off state.
    ///
    /// The body is intentionally empty — all stored properties carry inline defaults.
    /// The explicit `public init()` ensures the type is constructible from outside
    /// the module (Swift synthesises only an internal init by default for classes).
    public init() {
        // Intentionally empty — memberwise init is suppressed to ensure future stored
        // properties require an explicit default, surfacing signature changes at the call site.
    }
}
