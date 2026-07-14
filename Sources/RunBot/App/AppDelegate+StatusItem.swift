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
    /// loaded via `Bundle.module` (see below for why). Falls back to the SF
    /// Symbol chain when the asset is missing, preserving the original
    /// triple-fallback behaviour for safety.
    ///
    /// - Note: `status` is used only by the SF Symbol fallback chain (step 2).
    ///   `StatusBarIcon` is a static brand image and is status-agnostic; `status`
    ///   is intentionally ignored in the happy path.
    ///
    /// - Note: `template-rendering-intent: template` is set in Contents.json, and
    ///   `isTemplate = true` is also set explicitly (once, in `statusBarIcon`'s
    ///   initializer below) as belt-and-suspenders. Since `statusBarIcon` is a
    ///   cached `static let`, this mutation happens exactly once per process,
    ///   not per call.
    ///
    /// Fallback chain:
    /// 1. `Self.statusBarIcon` — bundled robot-face asset (template image),
    ///    loaded once via `Bundle.module.image(forResource:)` and cached (see
    ///    below). This is the only icon we want visible in the status bar
    ///    (issue #2079: a generic "circle" SF Symbol previously leaked through
    ///    as a fallback whenever the asset failed to load, which is exactly the
    ///    failure mode this app should surface loudly instead of hiding behind
    ///    a plausible-looking placeholder).
    ///
    ///    ⚠️ Deliberately NOT `NSImage(named:)`. `NSImage(named:)` only searches
    ///    `Bundle.main` (the app's flat Contents/Resources/ directory). SwiftPM
    ///    compiles Assets.xcassets into a *separate* nested resource bundle
    ///    (`RunBot_RunBot.bundle`), and copying that bundle into
    ///    Contents/Resources/ (see build.sh) does not make Bundle.main's own
    ///    asset-catalog lookup recurse into it — `NSImage(named:)` would still
    ///    return nil even with the copy step in place. `Bundle.module` is the
    ///    SwiftPM-synthesized accessor that resolves directly to that nested
    ///    bundle, so it is the only correct way to load this asset. Do NOT
    ///    revert to `NSImage(named:)` here.
    /// 2. `status.symbolName`             — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon asset is genuinely missing/corrupt.
    /// 3. `NSImage()`                     — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon asset missing from Bundle.module — check Package.swift `resources:` and build.sh bundle copy step (see issue #2079)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Cached `StatusBarIcon` image, loaded from `Bundle.module` exactly once.
    ///
    /// `Bundle.image(forResource:)` re-reads from disk on every call — unlike
    /// `NSImage(named:)`, it does not use AppKit's internal named-image cache.
    /// `updateStatusIcon()` calls `menuBarImage(for:)` on every runner-poll
    /// tick, so without this `static let` we'd pay a disk read + decode on
    /// every tick. Computed once, lazily, on first access.
    private static let statusBarIcon: NSImage? = {
        let icon = Bundle.module.image(forResource: "StatusBarIcon")
        icon?.isTemplate = true  // belt-and-suspenders on top of Contents.json
        return icon
    }()
}
