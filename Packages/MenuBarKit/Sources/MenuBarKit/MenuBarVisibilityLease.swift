// MenuBarVisibilityLease.swift
// MenuBarKit
//
// Temporarily requests a visible, non-auto-hiding menu bar while an MBK panel
// session is active.
//
// This is intentionally process-scoped:
//   - Never modifies global preferences.
//   - Snapshots the complete presentation-options value.
//   - Restores that exact value when the panel closes.
//   - Never explicitly hides the menu bar on release.

import AppKit

/// Scoped menu-bar visibility lease for `MBKPanelController`.
///
/// Acquire once when the panel opens; release once when it closes.
/// Every open path must funnel through a corresponding release — including
/// forced sheet dismissal and errors encountered after acquisition.
@MainActor
final class MBKMenuBarVisibilityLease {

    /// Presentation options captured when the lease was acquired.
    /// `nil` means there is no active lease.
    private var savedOptions: NSApplication.PresentationOptions?

    /// Whether this lease currently owns a presentation-options snapshot.
    var isActive: Bool {
        savedOptions != nil
    }

    /// Returns presentation options with menu-bar hiding removed while
    /// preserving every unrelated option.
    nonisolated static func pinnedOptions(
        from options: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        var result = options
        result.remove(.autoHideMenuBar)
        result.remove(.hideMenuBar)
        return result
    }

    /// Acquires the lease once. Repeated acquisition is an idempotent no-op.
    func acquire() {
        guard savedOptions == nil else {
            mbkLog("MenuBarVisibilityLease", "acquire -- already active")
            return
        }

        let original = NSApp.presentationOptions
        let pinned = Self.pinnedOptions(from: original)

        savedOptions = original
        NSApp.presentationOptions = pinned
        NSMenu.setMenuBarVisible(true)

        mbkLog(
            "MenuBarVisibilityLease",
            """
            acquire -- \
            originalOptions=\(original.rawValue) \
            pinnedOptions=\(pinned.rawValue) \
            menuBarVisible=\(NSMenu.menuBarVisible())
            """
        )
    }

    /// Restores the exact options captured by `acquire()`.
    ///
    /// Does not call `NSMenu.setMenuBarVisible(false)`: AppKit and the user's
    /// system preference decide when the menu bar should retract afterward.
    func release() {
        guard let original = savedOptions else {
            mbkLog("MenuBarVisibilityLease", "release -- inactive")
            return
        }

        NSApp.presentationOptions = original
        savedOptions = nil

        mbkLog(
            "MenuBarVisibilityLease",
            """
            release -- \
            restoredOptions=\(original.rawValue) \
            menuBarVisible=\(NSMenu.menuBarVisible())
            """
        )
    }
}
