// PanelControllerProtocol.swift
// MenuBarKit
//
// Protocol surface for MBKPanelController.

import AppKit
import SwiftUI

/// Protocol surface for `MBKPanelController`.
@MainActor
public protocol MBKPanelControllerProtocol: AnyObject {

    /// Wires the status item, panel, and observers.
    /// Call from `applicationDidFinishLaunching` before any user interaction.
    func setup()

    /// Updates the status-bar button image.
    /// The caller is responsible for supplying an appropriately sized, template-mode
    /// `NSImage`. `MBKPanelController` does not resize or retemplate the image.
    func setStatusItemImage(_ image: NSImage)

    /// Invalidates the hosting view's intrinsic content size and schedules a
    /// measurement on the next layout pass. Call this when the SwiftUI content
    /// changes size but the standard KVO observer has not fired yet (e.g. data
    /// changes inside a ScrollView that do not trigger preferredContentSize).
    /// Safe to call while the panel is closed — the measurement is skipped.
    func invalidateContentSize()

    /// Called in `openPanel()` before the panel is ordered front.
    /// Safe for restoring route and other state with no overlay gate side effects.
    var onWillShow: (() -> Void)? { get set }

    /// Called via `Task { @MainActor }` after the panel is ordered front — one
    /// actor-turn hop, not a full render cycle. In practice `NSHostingView`
    /// performs its first layout synchronously, so the view tree has a window by
    /// the time this fires. Do not write timing-sensitive code that assumes a
    /// full SwiftUI render pass has completed.
    /// Use this to restore `isSheetPresented` and any state that arms the overlay gate.
    ///
    /// ⚠️ OVERLAY GATE TIMING: if you set a property here that drives `.mbkSheet`
    /// (e.g. `isSheetPresented = true`), the overlay gate (`hasActiveOverlay`) is NOT
    /// armed immediately. `MBKAnchoredSheetModifier.onChange` fires on the *next*
    /// SwiftUI render pass — one additional hop after this callback. An outside click
    /// that arrives in that gap will see `hasActiveOverlay = false` and perform a
    /// normal close instead of a force-close. Treat `onDidShow` state restoration as
    /// best-effort for instant-dismiss scenarios immediately after open.
    var onDidShow: (() -> Void)? { get set }

    /// Called before any teardown whenever the panel closes.
    /// `wasForced` is `true` when the close was triggered by an outside click while a
    /// sheet was active (force-close path). Use this to reset live sheet state so SwiftUI
    /// tears down the sheet window before the panel closes.
    /// `wasForced` is `false` on a normal user-dismissed close — sheet state is already
    /// gone, no reset needed.
    /// Note: treat `wasForced` as advisory — see README Known Limitations for the
    /// fast-dismiss TOCTOU edge case that can produce a spurious `wasForced=true`.
    var onWillClose: ((_ wasForced: Bool) -> Void)? { get set }
}
