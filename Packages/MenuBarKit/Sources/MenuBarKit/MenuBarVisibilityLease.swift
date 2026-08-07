// MenuBarVisibilityLease.swift
// MenuBarKit
//
// Scoped ownership of the system menu bar's presentation state while the
// custom panel is visible.

import AppKit

/// Acquires and releases an AppKit-level menu-bar visibility lease for the
/// lifetime of a single `MBKPanel` session.
///
/// **Design intent**
///
/// When the user sets System Settings → Menu Bar → Automatically hide and show
/// the menu bar to **Always**, the system menu bar retracts shortly after the
/// pointer leaves the menu-bar strip. RunBot's status item lives in that strip,
/// so retraction makes the status item inaccessible and the panel loses its
/// anchor parent.
///
/// This lease strips both `.autoHideMenuBar` and `.hideMenuBar` from the
/// process-scoped `NSApplication.presentationOptions` while the panel is open,
/// and calls `NSMenu.setMenuBarVisible(true)` to reveal the bar. On release,
/// the exact prior `presentationOptions` value is restored — the lease never
/// writes user defaults, never forces the bar hidden, and never assumes what
/// the "default" options are.
///
/// **Lifecycle**
///
/// - `acquire()` — idempotent; captures and saves the current options, then
///   clears the auto-hide/hide flags.
/// - `release()` — idempotent; restores the saved options captured at the
///   most recent `acquire()` call.
///
/// **Thread safety**
///
/// This class is `@MainActor`-bound. All calls must happen on the main actor,
/// which is guaranteed by the `MBKPanelController` lifecycle.
///
/// **Non-goals**
///
/// - This lease does not use SkyLight or any other private API.
/// - It does not write `_HIHideMenuBar`, `AppleMenuBarVisibleInFullscreen`,
///   or any other user default.
/// - It does not shell out to `defaults`.
/// - It never calls `NSMenu.setMenuBarVisible(false)`.
@MainActor
final class MBKMenuBarVisibilityLease {

    /// The presentation options captured at the most recent `acquire()` call.
    /// `nil` when the lease is inactive.
    private var savedOptions: NSApplication.PresentationOptions?

    /// Whether the lease is currently active.
    var isActive: Bool {
        savedOptions != nil
    }

    /// Acquires the lease: saves the current presentation options, clears the
    /// auto-hide and hide flags, and reveals the menu bar.
    ///
    /// - Returns: `true` when AppKit reports the menu bar visible immediately
    ///   after the request. This is a diagnostic signal, not a guarantee that
    ///   the bar will remain pinned after the pointer leaves the menu-bar
    ///   tracking region.
    @discardableResult
    func acquire() -> Bool {
        guard savedOptions == nil else {
            mbkLog("MenuBarLease", "acquire -- already active")
            return NSMenu.menuBarVisible()
        }

        let current = NSApp.presentationOptions
        var pinned = current
        pinned.remove(.autoHideMenuBar)
        pinned.remove(.hideMenuBar)

        savedOptions = current
        NSApp.presentationOptions = pinned
        NSMenu.setMenuBarVisible(true)

        let visible = NSMenu.menuBarVisible()
        mbkLog(
            "MenuBarLease",
            "acquire -- visible=\(visible) before=\(current.rawValue) after=\(pinned.rawValue)"
        )
        return visible
    }

    /// Releases the lease: restores the exact presentation options that were
    /// captured at the most recent `acquire()` call.
    ///
    /// This is idempotent — calling `release()` when the lease is already
    /// inactive is a no-op.
    func release() {
        guard let savedOptions else {
            mbkLog("MenuBarLease", "release -- inactive, ignored")
            return
        }

        NSApp.presentationOptions = savedOptions
        self.savedOptions = nil

        mbkLog(
            "MenuBarLease",
            "release -- visible=\(NSMenu.menuBarVisible()) restored=\(savedOptions.rawValue)"
        )
    }
}