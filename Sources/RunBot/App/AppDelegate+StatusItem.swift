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
    /// Prefers the bundled `StatusBarIcon` asset (the robot-face template image),
    /// loaded from the compiled asset catalog (`Assets.car`) via
    /// `NSImage(named:)` — see `statusBarIcon` below.
    ///
    /// Falls back to the SF Symbol chain when the asset is missing, preserving
    /// the original triple-fallback behaviour for safety.
    ///
    /// - Note: `status` is used only by the SF Symbol fallback chain (step 2).
    ///   `StatusBarIcon` is a static brand image and is status-agnostic.
    ///
    /// Fallback chain:
    /// 1. `Self.statusBarIcon` — robot-face asset from compiled catalog.
    /// 2. `status.symbolName`  — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon asset is genuinely missing/corrupt.
    /// 3. `NSImage()`          — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon missing from Assets.car — check Assets.xcassets is declared in project.yml sources with buildPhase: resources and xcodebuild ran actool (see issue #2763)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Logical (point) size the icon renders at in the menu bar, regardless
    /// of which @Nx pixel representation AppKit picks for the display. 18pt
    /// is the standard macOS menu bar icon convention.
    private static let statusBarIconPointSize = NSSize(width: 18, height: 18)

    /// Cached `StatusBarIcon` image, loaded from the compiled asset catalog
    /// (`Assets.car`) exactly once via `NSImage(named:)`.
    ///
    /// xcodebuild runs `actool` which compiles
    /// `Sources/RunBot/Resources/Assets.xcassets` into
    /// `Contents/Resources/Assets.car`. `NSImage(named:)` resolves named
    /// images from that catalog automatically via `Bundle.main`.
    ///
    /// ⚠️  AI AGENT: Do NOT revert to loose-file loading via
    /// `Bundle.main.path(forResource:ofType:)`. Do NOT use `Bundle.module`
    /// or a SwiftPM resource bundle. The asset catalog is compiled by
    /// xcodebuild/actool — it is NOT available in `swift build` debug builds.
    /// See issue #2763 for the xcodebuild migration that makes this possible.
    private static let statusBarIcon: NSImage? = {
        guard let image = NSImage(named: "StatusBarIcon")?.copy() as? NSImage else {
            return nil
        }
        // Explicitly set the logical point size so the menu-bar icon renders
        // at 18×18 pt on all displays, regardless of the intrinsic size baked
        // into the asset catalog. Without this, AppKit infers the size from the
        // imageset's contents, which may differ from the 18pt convention.
        // isTemplate enables automatic light/dark inversion by the system.
        image.size = statusBarIconPointSize
        image.isTemplate = true
        return image
    }()
}
