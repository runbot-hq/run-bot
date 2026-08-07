// MenuBarVisibilityLease.swift
// MenuBarKit
//
// Scoped ownership of the system menu bar's presentation state while the
// custom panel is visible.

import AppKit

/// Acquires and releases a menu-bar visibility lease for the lifetime of a
/// single `MBKPanel` session.
///
/// The lease uses two layers:
///  1. **Public AppKit lease** — strips `.autoHideMenuBar` and `.hideMenuBar`
///     from `NSApplication.presentationOptions` and calls
///     `NSMenu.setMenuBarVisible(true)`.
///  2. **Private SkyLight lease** — applies a display-scoped visibility override
///     via `SLSSetMenuBarVisibilityOverrideOnDisplay`. This is the primary hold
///     that keeps the bar visible even when the pointer is over another app.
///
/// The SkyLight backend is resolved at runtime via `dlopen`/`dlsym`. If the
/// symbols are unavailable (e.g., on a future macOS release), the lease degrades
/// to the public-only fallback — the panel opens normally, but menu-bar retention
/// may not be reliable when the pointer leaves the app.
///
/// **Lifecycle**
///
/// - `acquire(on:)` — idempotent; saves current presentation options, clears
///   auto-hide/hide flags, and acquires the SkyLight override on the given
///   screen's display.
/// - `release()` — idempotent; clears the SkyLight override and restores the
///   saved options.
///
/// **Thread safety**
///
/// This class is `@MainActor`-bound. All calls must happen on the main actor,
/// which is guaranteed by the `MBKPanelController` lifecycle.
@MainActor
final class MBKMenuBarVisibilityLease {

    // MARK: - Public lease state

    /// The presentation options captured at the most recent `acquire()` call.
    /// `nil` when the lease is inactive.
    private var savedOptions: NSApplication.PresentationOptions?

    /// Whether the public AppKit lease is currently active.
    var isActive: Bool {
        savedOptions != nil
    }

    // MARK: - Private SkyLight lease state

    /// The display ID currently held by the SkyLight override.
    /// `nil` when no private override is active.
    private var heldDisplayID: CGDirectDisplayID?

    /// Whether the SkyLight private override is currently active.
    var isPrivateOverrideActive: Bool {
        heldDisplayID != nil
    }

    // MARK: - Acquire

    /// Acquires the lease on the given screen's display.
    ///
    /// 1. Saves and adjusts the public `NSApplication.presentationOptions` (first
    ///    call only).
    /// 2. Applies a SkyLight visibility override on the display of `screen`.
    ///    If SkyLight is unavailable, logs and returns the public-visibility result.
    ///
    /// - Parameter screen: The screen whose display should hold the menu bar
    ///   visible. When `nil`, only the public lease is applied.
    /// - Returns: `true` when AppKit reports the menu bar visible immediately
    ///   after the request.
    @discardableResult
    func acquire(on screen: NSScreen?) -> Bool {
        // --- Public lease ---
        if savedOptions == nil {
            let current = NSApp.presentationOptions
            var pinned = current
            pinned.remove(.autoHideMenuBar)
            pinned.remove(.hideMenuBar)

            savedOptions = current
            NSApp.presentationOptions = pinned
            NSMenu.setMenuBarVisible(true)
        }

        let visible = NSMenu.menuBarVisible()

        // --- Private SkyLight lease ---
        guard let displayID = Self.displayID(for: screen) else {
            mbkLog("MenuBarLease", "private unavailable -- no display ID, screen=\(screen.map { "\($0)" } ?? "nil")")
            return visible
        }

        guard let mainConnectionID = MBKSkyLight.mainConnectionID,
              let setOverride = MBKSkyLight.setMenuBarVisibilityOverride
        else {
            mbkLog("MenuBarLease", "private unavailable -- SkyLight symbols not found")
            return visible
        }

        let cid = mainConnectionID()

        if let existing = heldDisplayID {
            if existing == displayID {
                // Same display — reassert.
                let error = setOverride(cid, displayID, true)
                if error != .success {
                    mbkLog("MenuBarLease", "private reassert -- error=\(error.rawValue) cid=\(cid) display=\(displayID)")
                } else {
                    mbkLog("MenuBarLease", "private reassert -- cid=\(cid) display=\(displayID) error=\(error.rawValue)")
                }
            } else {
                // Different display — transactional migration: clear old before acquiring new.
                let clearError = setOverride(cid, existing, false)
                mbkLog(
                    "MenuBarLease",
                    "private move-clear -- cid=\(cid) display=\(existing) error=\(clearError.rawValue)"
                )

                guard clearError == .success else {
                    // Keep tracking the old display so release() can retry cleanup.
                    mbkLog(
                        "MenuBarLease",
                        "private move-abort -- oldDisplay=\(existing) newDisplay=\(displayID)"
                    )
                    return visible
                }

                heldDisplayID = nil

                let acquireError = setOverride(cid, displayID, true)
                if acquireError == .success {
                    heldDisplayID = displayID
                }

                mbkLog(
                    "MenuBarLease",
                    "private acquire -- cid=\(cid) display=\(displayID) "
                        + "error=\(acquireError.rawValue) active=\(heldDisplayID != nil)"
                )
            }
        } else {
            // First acquisition on this display.
            let error = setOverride(cid, displayID, true)
            if error == .success {
                heldDisplayID = displayID
            }
            mbkLog("MenuBarLease", "private acquire -- cid=\(cid) display=\(displayID) error=\(error.rawValue) active=\(heldDisplayID != nil)")
        }

        return visible
    }

    // MARK: - Release

    /// Releases the lease: clears the SkyLight override and restores the exact
    /// presentation options that were captured at the most recent `acquire()` call.
    ///
    /// This is idempotent — calling `release()` when the lease is already
    /// inactive is a no-op.
    ///
    /// WindowServer state is cleared **before** the public lease restoration.
    /// If public/private state becomes desynchronized, the private cleanup still
    /// runs unconditionally.
    func release() {
        // WindowServer state is higher risk than process-local presentation state.
        // Always attempt private cleanup, even if the public lease is inactive.
        clearPrivateOverride()

        guard let options = savedOptions else {
            mbkLog("MenuBarLease", "release -- public lease inactive")
            return
        }

        // Restore public options.
        NSApp.presentationOptions = options
        savedOptions = nil

        mbkLog(
            "MenuBarLease",
            "release -- visible=\(NSMenu.menuBarVisible()) restored=\(options.rawValue)"
        )
    }

    // MARK: - Private helpers

    /// Resolves the `CGDirectDisplayID` for the given screen, falling back to
    /// `NSScreen.main` when the parameter is `nil`.
    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let screen = screen ?? NSScreen.main,
              let number = screen.deviceDescription[
                  NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else {
            return nil
        }
        return number.uint32Value
    }

    /// Clears the SkyLight override on the currently held display, if any.
    /// Never restores public options — that is the caller's responsibility.
    private func clearPrivateOverride() {
        guard let displayID = heldDisplayID else { return }
        defer { heldDisplayID = nil }

        guard let mainConnectionID = MBKSkyLight.mainConnectionID,
              let setOverride = MBKSkyLight.setMenuBarVisibilityOverride
        else {
            mbkLog("MenuBarLease", "private release -- SkyLight unavailable, display=\(displayID)")
            return
        }

        let cid = mainConnectionID()
        let error = setOverride(cid, displayID, false)
        if error != .success {
            mbkLog("MenuBarLease", "private release -- error=\(error.rawValue) cid=\(cid) display=\(displayID)")
        } else {
            mbkLog("MenuBarLease", "private release -- cid=\(cid) display=\(displayID) error=\(error.rawValue)")
        }
    }
}
