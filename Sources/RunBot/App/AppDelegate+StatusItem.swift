// AppDelegate+StatusItem.swift
// RunBot
import AppKit
import RunBotCore

// MARK: - AppDelegate + Status Item
//
// As of #2262, NSStatusItem creation and toggle wiring are owned by
// MBKPanelController.setup(). This file owns only icon-update logic
// and the menuBarImage helper that maps AggregateStatus to the correct image.
//
// updateStatusIcon() is passed as a callback to appState.start() so AppState
// never imports AppKit or holds a reference to AppDelegate.
//
// ❌ NEVER inline this back into AppDelegate.swift.

/// Extension owning icon updates and the `menuBarImage` helper.
extension AppDelegate {

    // MARK: - Icon updates

    /// Updates the menu-bar icon to reflect the current aggregate runner status.
    /// ❌ NEVER filter by !isDimmed only — dimmed groups can still have in-progress jobs.
    /// ❌ NEVER read RunnerPoller.shared.jobs here — it is almost always empty.
    /// ❌ NEVER call makeStatusIcon() — it no longer exists; use menuBarImage(for:).
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE.
    func updateStatusIcon() {
        // `aggregateStatus` is derived from `runnerState.runners` which `RunnerPoller`
        // pushes to `RunnerState` via `MainActor.run` after every fetch cycle.
        let status = AggregateStatus(runners: appState.runnerState.runners)
        panelController?.setStatusItemImage(menuBarImage(for: status))
    }

    // MARK: - Image helper

    /// Returns the menu-bar icon for the given aggregate status.
    ///
    /// Loads `StatusBarIcon` from loose PNG files in `Bundle.main` — the
    /// proven mechanism from main's build pipeline. build.sh explicitly copies
    /// StatusBarIcon.png / @2x / @3x into Contents/Resources, so all three
    /// representations are always present regardless of actool behaviour.
    ///
    /// Falls back to the SF Symbol chain when the loose files are missing,
    /// preserving the original triple-fallback behaviour for safety.
    ///
    /// - Note: `status` is used only by the SF Symbol fallback chain (step 2).
    ///   `StatusBarIcon` is a static brand image and is status-agnostic.
    ///
    /// Fallback chain:
    /// 1. `Self.statusBarIcon` — robot-face image loaded from loose PNGs.
    /// 2. `status.symbolName`  — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon PNGs are genuinely missing.
    /// 3. `NSImage()`          — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon missing from Bundle.main — check build.sh copies StatusBarIcon.png/@2x/@3x into Contents/Resources (see issue #2775)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Logical (point) size the icon renders at in the menu bar, regardless
    /// of which @Nx pixel representation AppKit picks for the display. 18pt
    /// is the standard macOS menu bar icon convention.
    private static let statusBarIconPointSize = NSSize(width: 18, height: 18)

    /// Cached `StatusBarIcon` image, loaded from loose PNG files in
    /// `Bundle.main` exactly once.
    ///
    /// build.sh explicitly copies StatusBarIcon.png, StatusBarIcon@2x.png, and
    /// StatusBarIcon@3x.png from the imageset into Contents/Resources before
    /// codesigning. `Bundle.main.path(forResource:ofType:)` resolves each
    /// representation by filename; they are composed into a single NSImage with
    /// the correct pixel density metadata so AppKit picks the right one per
    /// display. This mirrors main's proven icon-loading mechanism exactly.
    ///
    /// ⚠️  AI AGENT: Do NOT switch to `NSImage(named:)` or `Bundle.module`.
    /// `NSImage(named:)` requires Assets.car (actool output) which is not
    /// reliably produced by the current XcodeGen resource phase. `Bundle.module`
    /// is a SwiftPM resource bundle unavailable in xcodebuild app targets.
    /// The loose-file approach is deliberate — see issue #2775.
    private static let statusBarIcon: NSImage? = {
        let filenames = ["StatusBarIcon", "StatusBarIcon@2x", "StatusBarIcon@3x"]
        let image = NSImage()
        image.size = statusBarIconPointSize

        for filename in filenames {
            guard let path = Bundle.main.path(forResource: filename, ofType: "png"),
                  let rep = NSBitmapImageRep(contentsOfFile: path) else {
                continue
            }
            image.addRepresentation(rep)
        }

        guard image.representations.isEmpty == false else {
            return nil
        }

        image.isTemplate = true
        return image
    }()
}
