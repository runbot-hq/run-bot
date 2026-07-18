// AppDelegate+StatusItem.swift
// RunBot
import AppKit
import RunBotCore

// MARK: - AppDelegate + Status Item
//
// Owns NSStatusItem creation, menu-bar icon updates, and the menuBarImage
// helper that maps AggregateStatus to the correct SF Symbol.
// Called once from applicationDidFinishLaunching via setupStatusItem().
//
// ❌ NEVER inline this back into AppDelegate.swift.
// ❌ NEVER call setupStatusItem() more than once.

/// Extension owning NSStatusItem creation, icon updates, and the `menuBarImage` helper.
extension AppDelegate {

    // MARK: Status item setup

    /// Creates the NSStatusItem, sets the initial icon, and wires the toggle action.
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = menuBarImage(for: .allOffline)
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    // MARK: Icon updates

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
        statusItem?.button?.image = menuBarImage(for: status)
    }

    // MARK: Image helper

    /// Returns the menu-bar icon for the given aggregate status.
    ///
    /// Prefers the bundled `StatusBarIcon` asset (the robot-face template PNG),
    /// loaded via `Bundle.main` from `Contents/Resources/` — see `statusBarIcon`
    /// below for why `Bundle.module` is NOT used here.
    ///
    /// Falls back to the SF Symbol chain when the asset is missing, preserving
    /// the original triple-fallback behaviour for safety.
    ///
    /// - Note: `status` is used only by the SF Symbol fallback chain (step 2).
    ///   `StatusBarIcon` is a static brand image and is status-agnostic.
    ///
    /// Fallback chain:
    /// 1. `Self.statusBarIcon` — bundled robot-face asset (template image),
    ///    loaded once and cached.
    /// 2. `status.symbolName`  — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon asset is genuinely missing/corrupt.
    /// 3. `NSImage()`          — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon asset missing from Contents/Resources — check build.sh copies StatusBarIcon*.png (see issue #2139)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Logical (point) size the icon renders at in the menu bar, regardless
    /// of which @Nx pixel representation AppKit picks for the display. 18pt
    /// is the standard macOS menu bar icon convention.
    private static let statusBarIconPointSize = NSSize(width: 18, height: 18)

    /// Cached `StatusBarIcon` image, loaded from `Bundle.main` exactly once.
    ///
    /// ⚠️  AI AGENT: Do NOT switch this back to `Bundle.module`.
    ///
    /// WHY Bundle.main, NOT Bundle.module:
    /// SwiftPM's auto-generated resource_bundle_accessor.swift resolves
    /// Bundle.module via Bundle.main.bundleURL (the app root: RunBot.app/).
    /// codesign hard-rejects any directory at the app root other than Contents/
    /// with "unsealed contents present in the bundle root".
    /// Moving the bundle to Contents/Resources/ is codesign-safe, but the
    /// binary never looks there — it looks at the app root. Crash on every
    /// clean install.
    ///
    /// Fix (issue #2139): remove resources: [.process("Resources")] from
    /// Package.swift entirely. No SwiftPM bundle, no generated accessor,
    /// no conflict. The three PNG files are shipped as loose files in
    /// Contents/Resources/ by build.sh, and loaded here via Bundle.main
    /// which correctly resolves to Contents/Resources/ for a packaged .app.
    ///
    /// WHY literal path loading (not NSImage(named:) or image(forResource:)):
    /// `swift build` does NOT run actool — Assets.xcassets is never compiled
    /// into Assets.car. NSImage(named:) needs a compiled catalog. The PNGs
    /// are now loose files, so Bundle.main.path(forResource:ofType:) finds
    /// them directly by filename. The @Nx suffix is handled manually below
    /// so AppKit gets all three representations and picks the sharpest one
    /// for the current display — the same behaviour a compiled catalog gives.
    ///
    /// Do NOT revert to Bundle.module. Do NOT use NSImage(named:).
    /// Do NOT reintroduce resources: [.process("Resources")] in Package.swift
    /// without reading issues #2139 and #2136 first.
    private static let statusBarIcon: NSImage? = {
        let combinedIcon = NSImage(size: statusBarIconPointSize)
        var loadedAny = false

        for scale in [1, 2, 3] {
            let filename = scale == 1 ? "StatusBarIcon" : "StatusBarIcon@\(scale)x"
            // Bundle.main.path(forResource:ofType:) finds loose files in
            // Contents/Resources/ — exactly where build.sh places the PNGs.
            // No inDirectory: needed — the PNGs are at the Contents/Resources/ root.
            guard let path = Bundle.main.path(forResource: filename, ofType: "png"),
                  let data = NSData(contentsOfFile: path),
                  let rep = NSBitmapImageRep(data: data as Data) else {
                continue
            }
            rep.size = statusBarIconPointSize
            combinedIcon.addRepresentation(rep)
            loadedAny = true
        }

        guard loadedAny else {
            #if DEBUG
            assertionFailure("StatusBarIcon PNGs missing from Contents/Resources — check build.sh (see issue #2139)")
            #endif
            return nil
        }

        combinedIcon.isTemplate = true
        return combinedIcon
    }()
}
