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
    /// Prefers `StatusBarIcon` — a flat PNG copied into `Contents/Resources/`
    /// by `build.sh` — loaded once via `Bundle.main` and cached in
    /// `statusBarIcon`. Falls back to the status-appropriate SF Symbol if the
    /// file is missing (surfaces the problem rather than silently showing a
    /// generic placeholder).
    ///
    /// - Note: `status` is intentionally ignored in the happy path;
    ///   `StatusBarIcon` is a static brand image.
    ///
    /// Fallback chain:
    /// 1. `Self.statusBarIcon` — flat PNG from `Contents/Resources/`, loaded
    ///    once via `Bundle.main.image(forResource:)` and cached.
    ///
    ///    ⚠️ Deliberately NOT `Bundle.module`. When building with
    ///    `swift build --arch arm64`, SwiftPM copies `Assets.xcassets` as a
    ///    raw folder (not compiled to `Assets.car`), so
    ///    `Bundle.module.image(forResource:)` returns nil at runtime.
    ///    A flat PNG in `Contents/Resources/` sidesteps the asset-catalog
    ///    pipeline entirely and is reliably found by `Bundle.main`. Do NOT
    ///    revert to `Bundle.module` or `NSImage(named:)` here.
    /// 2. `status.symbolName` — status-appropriate SF Symbol.
    ///    Reached only if `StatusBarIcon.png` is missing from the bundle.
    /// 3. `NSImage()` — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon.png missing from Bundle.main — check build.sh PNG copy step (see issue #2079)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Cached robot-head icon, loaded from `Bundle.main` exactly once.
    ///
    /// `build.sh` copies `StatusBarIcon@2x.png` from the asset imageset into
    /// `Contents/Resources/StatusBarIcon.png`. `Bundle.main.image(forResource:)`
    /// finds flat files in `Contents/Resources/` directly — no asset catalog,
    /// no nested bundle required. `isTemplate = true` makes AppKit render it
    /// correctly in both light and dark menu bars.
    private static let statusBarIcon: NSImage? = {
        let icon = Bundle.main.image(forResource: "StatusBarIcon")
        icon?.isTemplate = true
        return icon
    }()
}
