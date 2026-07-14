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
    /// loaded via `Bundle.module` by its literal path inside the (uncompiled)
    /// `Assets.xcassets` folder — see below for why. Falls back to the SF
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
    ///    loaded once and cached (see below). This is the only icon we want
    ///    visible in the status bar (issue #2079: a generic "circle" SF Symbol
    ///    previously leaked through as a fallback whenever the asset failed
    ///    to load, which is exactly the failure mode this app should surface
    ///    loudly instead of hiding behind a plausible-looking placeholder).
    ///
    ///    ⚠️ Deliberately NOT `NSImage(named:)` and NOT
    ///    `Bundle.module.image(forResource:)`. Both are asset-catalog/named-
    ///    image lookups that expect either a compiled `Assets.car` or a flat
    ///    file at the bundle root. `swift build` (used by build.sh) does
    ///    neither — it copies `Assets.xcassets` into the resource bundle
    ///    verbatim, uncompiled, as a real subdirectory tree. Confirmed by
    ///    direct runtime inspection: `Bundle.module`'s contents were just
    ///    `["Assets.xcassets"]`, no `.car`, no extracted PNGs at the root.
    ///    The only lookup that actually finds the file is one that knows the
    ///    literal nested path (`Assets.xcassets/StatusBarIcon.imageset/...`).
    ///    Do NOT revert to either of those APIs here.
    /// 2. `status.symbolName`             — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon asset is genuinely missing/corrupt.
    /// 3. `NSImage()`                     — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon asset missing from Bundle.module — check Sources/RunBot/Resources/Assets.xcassets/StatusBarIcon.imageset (see issue #2079)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Cached `StatusBarIcon` image, loaded from `Bundle.module` exactly once.
    ///
    /// - Important: `swift build` (the plain SwiftPM CLI toolchain used by
    ///   `build.sh`, as opposed to `xcodebuild`) does **not** run `actool` to
    ///   compile `Assets.xcassets` into `Assets.car`. It just copies the whole
    ///   `.xcassets` folder into the resource bundle verbatim, as a plain
    ///   subdirectory tree. Confirmed by direct runtime inspection during the
    ///   #2079 follow-up investigation: `Bundle.module`'s top-level directory
    ///   listing contained only `["Assets.xcassets"]` — no `Assets.car`, no
    ///   flattened/extracted PNGs at the bundle root.
    ///
    ///   This is why both `NSImage(named:)` (searches Bundle.main's asset
    ///   catalog machinery, which needs a compiled `.car`) and
    ///   `Bundle.module.image(forResource:)` / `path(forResource:ofType:)`
    ///   (flat, bundle-root-only lookups) returned `nil` — none of them know
    ///   to look three directories deep, inside
    ///   `Assets.xcassets/StatusBarIcon.imageset/`, for a scale-suffixed file.
    ///
    ///   The fix: build the path into the `.imageset` folder explicitly and
    ///   load the PNG directly with `NSImage(contentsOfFile:)`. This bypasses
    ///   asset-catalog/named-image lookup entirely, so it works the same
    ///   whether or not the catalog was ever compiled.
    ///
    /// - Note: `Bundle.image(forResource:)` also re-reads from disk on every
    ///   call, unlike `NSImage(named:)` which uses AppKit's internal
    ///   named-image cache — so this is cached as a `static let` regardless,
    ///   since `updateStatusIcon()` calls `menuBarImage(for:)` on every
    ///   runner-poll tick.
    private static let statusBarIcon: NSImage? = {
        // Picks the highest-scale PNG that exists for the current screen,
        // falling back to lower scales. @3x covers all current Apple Silicon
        // Retina displays; @2x/@1x are kept as a safety net for edge cases
        // (e.g. screen-recording/virtual displays reporting scale 1).
        let scale = Int((NSScreen.main?.backingScaleFactor ?? 2).rounded(.up))
        var candidateScales = [scale, 3, 2, 1]
        var seenScales = Set<Int>()
        candidateScales = candidateScales.filter { seenScales.insert($0).inserted }
        let imagesetDir = "Assets.xcassets/StatusBarIcon.imageset"

        for candidate in candidateScales {
            let filename = candidate == 1 ? "StatusBarIcon" : "StatusBarIcon@\(candidate)x"
            guard let path = Bundle.module.path(forResource: filename, ofType: "png", inDirectory: imagesetDir) else {
                continue
            }
            guard let icon = NSImage(contentsOfFile: path) else {
                continue
            }
            icon.isTemplate = true  // belt-and-suspenders on top of Contents.json
            return icon
        }

        #if DEBUG
        assertionFailure("StatusBarIcon asset missing from \(imagesetDir) in Bundle.module — check Sources/RunBot/Resources/Assets.xcassets/StatusBarIcon.imageset (see issue #2079)")
        #endif
        return nil
    }()
}
