// Panel.swift
// MenuBarKit
//
// The one real window MenuBarKit owns.
//
// ❌ NEVER add a second, invisible helper window to position this one. An
//    earlier attempt used a ghost `NSPanel` as an `NSPopover` positioning view;
//    it was rejected. This panel is anchored by arithmetic (`MBKPanelGeometry`),
//    not by AppKit anchoring.
import AppKit

/// Borderless, non-activating panel that hosts the menu-bar content.
///
/// Nonactivating so the frontmost app keeps its active state (matching the old
/// `NSPopover` UX), but `canBecomeKey` is overridden so text fields inside the
/// content can still take focus.
final class MBKPanel: NSPanel {

    /// Invoked when the user presses Escape while the panel is key.
    var onCancel: (@MainActor () -> Void)?

    /// Creates the panel with the style mask and window-level MenuBarKit relies on.
    init() {
        // .zero — NSWindow ignores contentRect for borderless panels; the real frame
        // is set by applyFrame() before orderFront. Not linked to fallbackContentSize.
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // Deliberately false: the panel must reliably take key status so that
        // Escape reaches `cancelOperation(_:)` through the responder chain, and
        // so that text fields in the content are focusable on the first click.
        // `.nonactivatingPanel` already keeps the previous app from being disturbed
        // more than the old NSPopover did.
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    /// Text fields inside the content need focus, so the panel must be able to become key.
    override var canBecomeKey: Bool { true }

    /// The panel must never become the main window — the user's app stays main.
    override var canBecomeMain: Bool { false }

    /// Routes Escape (keyCode 53) to `onCancel` instead of beeping.
    /// - Parameter sender: The responder-chain sender; unused.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
