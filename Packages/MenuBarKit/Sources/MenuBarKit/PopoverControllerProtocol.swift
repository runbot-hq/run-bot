// PopoverControllerProtocol.swift
// MenuBarKit
//
// Protocol surface for MBKPopoverController.

import AppKit
import SwiftUI

/// Protocol surface for `MBKPopoverController`.
@MainActor
public protocol MBKPopoverControllerProtocol: AnyObject {

    /// Wires the status item, popover, and observers.
    /// Call from `applicationDidFinishLaunching` before any user interaction.
    func setup()

    /// Replaces the popover's root view with `view`.
    /// MBKPopoverController's GeometryReader picks up the size change automatically.
    /// Call this whenever you want to navigate to a different top-level view
    /// without closing and reopening the popover.
    /// ❌ NEVER call from a SwiftUI view — use callbacks only.
    func setRootView(_ view: AnyView)

    /// Updates the status-bar button image.
    /// The caller is responsible for supplying an appropriately sized, template-mode
    /// `NSImage`. `MBKPopoverController` does not resize or retemplate the image.
    func setStatusItemImage(_ image: NSImage)

    /// Called in `openPopover()` before `popover.show()`.
    /// Safe for restoring route and other state with no overlay gate side effects.
    var onWillShow: (() -> Void)? { get set }

    /// Called via `Task { @MainActor }` after `popover.show()` — one actor-turn
    /// hop, not a full CADisplayLink render cycle. In practice `NSHostingController`
    /// performs its first layout synchronously during `show()`, so the view tree
    /// has a window by the time this fires. Do not write timing-sensitive code
    /// that assumes a full SwiftUI render pass has completed.
    /// Use this to restore `isSheetPresented` and any state that arms the overlay gate.
    ///
    /// ⚠️ OVERLAY GATE TIMING: if you set a property here that drives `.mbkSheet`
    /// (e.g. `isSheetPresented = true`), the overlay gate (`hasActiveOverlay`) is NOT
    /// armed immediately. `MBKAnchoredSheetModifier.onChange` fires on the *next*
    /// SwiftUI render pass — one additional hop after this callback. An outside click
    /// that arrives in that gap will see `hasActiveOverlay = false` and call
    /// `performClose` instead of `forceClose`. Treat `onDidShow` state restoration as
    /// best-effort for instant-dismiss scenarios immediately after open.
    var onDidShow: (() -> Void)? { get set }

    /// Called before any teardown whenever the popover closes.
    /// `wasForced` is `true` when the close was triggered by an outside click while a
    /// sheet was active (force-close path). Use this to reset live sheet state so SwiftUI
    /// tears down the sheet window before the popover closes.
    /// `wasForced` is `false` on a normal user-dismissed close — sheet state is already
    /// gone, no reset needed.
    /// Note: treat `wasForced` as advisory — see README Known Limitations for the
    /// fast-dismiss TOCTOU edge case that can produce a spurious `wasForced=true`.
    var onWillClose: ((_ wasForced: Bool) -> Void)? { get set }
}
