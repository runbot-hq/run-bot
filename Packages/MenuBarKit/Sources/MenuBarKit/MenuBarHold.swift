// MenuBarHold.swift
// MenuBarKit
//
// Scoped SkyLight menu-bar visibility override for an open status-item panel.

import AppKit

/// Holds the system menu bar visible on one display for one panel session.
///
/// This type intentionally has no public AppKit presentation-state layer and no
/// display-migration state machine. It acquires once at panel open and releases
/// the exact same display at panel close or normal application termination.
@MainActor
final class MBKMenuBarHold {

    /// The display currently held through SkyLight, or `nil` when inactive.
    private var heldDisplayID: CGDirectDisplayID?

    /// Whether a SkyLight override was acquired successfully.
    var isActive: Bool {
        heldDisplayID != nil
    }

    /// Attempts to hold the menu bar visible on `screen`.
    ///
    /// Missing screens, display IDs, framework images, symbols, or nonzero
    /// SkyLight errors safely degrade to no-op behavior. The panel must still
    /// open normally.
    ///
    /// Repeated acquisition while already active is ignored. This PR has one
    /// acquisition per panel session and does not implement retargeting.
    ///
    /// - Parameter screen: The status-item button window's current screen.
    func acquire(on screen: NSScreen?) {
        guard heldDisplayID == nil else {
            mbkLog(
                "MenuBarHold",
                "acquire -- already active display=\(heldDisplayID ?? 0)"
            )
            return
        }

        guard let screen else {
            mbkLog("MenuBarHold", "acquire -- no status-item screen")
            return
        }

        guard let displayID = Self.displayID(for: screen) else {
            mbkLog("MenuBarHold", "acquire -- no display ID")
            return
        }

        guard let mainConnectionID = MBKSkyLight.mainConnectionID,
              let setOverride = MBKSkyLight.setMenuBarVisibilityOverride
        else {
            mbkLog("MenuBarHold", "acquire -- SkyLight unavailable")
            return
        }

        let connectionID = mainConnectionID()
        let error = setOverride(connectionID, displayID, true)

        if error == .success {
            heldDisplayID = displayID
        }

        mbkLog(
            "MenuBarHold",
            "acquire -- cid=\(connectionID) display=\(displayID) "
                + "error=\(error.rawValue) active=\(heldDisplayID != nil)"
        )
    }

    /// Releases the currently held display override, if any.
    ///
    /// The stored ID is cleared after the attempt even when SkyLight returns an
    /// error. Errors are logged; release never blocks panel teardown.
    func release() {
        guard let displayID = heldDisplayID else {
            return
        }
        defer { heldDisplayID = nil }

        guard let mainConnectionID = MBKSkyLight.mainConnectionID,
              let setOverride = MBKSkyLight.setMenuBarVisibilityOverride
        else {
            mbkLog(
                "MenuBarHold",
                "release -- SkyLight unavailable display=\(displayID)"
            )
            return
        }

        let connectionID = mainConnectionID()
        let error = setOverride(connectionID, displayID, false)

        mbkLog(
            "MenuBarHold",
            "release -- cid=\(connectionID) display=\(displayID) "
                + "error=\(error.rawValue)"
        )
    }

    /// Returns the Core Graphics display ID represented by `screen`.
    private static func displayID(
        for screen: NSScreen
    ) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber)?.uint32Value
    }
}
