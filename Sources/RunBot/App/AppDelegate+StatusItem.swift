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
    /// loaded via `RunBotResources.bundle` by its literal path inside the
    /// (uncompiled) `Assets.xcassets` folder — see below for why. Falls back
    /// to the SF Symbol chain when the asset is missing, preserving the original
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
    ///    `Bundle.module.image(forResource:)` and NOT `Bundle.module` directly.
    ///    See `RunBotResources.swift` for why `Bundle.module` must not be used
    ///    here — its generated lookup probes the app root, which codesign rejects.
    ///    `swift build` (used by build.sh) does not run actool — Assets.xcassets
    ///    is copied verbatim into the resource bundle as an uncompiled directory
    ///    tree. The only lookup that finds the file is one that knows the literal
    ///    nested path (`Assets.xcassets/StatusBarIcon.imageset/...`).
    ///    Do NOT revert to either of those APIs here.
    /// 2. `status.symbolName`             — correct SF Symbol for the current status.
    ///    Reached only if the StatusBarIcon asset is genuinely missing/corrupt.
    /// 3. `NSImage()`                     — empty/invisible (should never be reached).
    func menuBarImage(for status: AggregateStatus) -> NSImage {
        if let icon = Self.statusBarIcon {
            return icon
        }
        #if DEBUG
        assertionFailure("StatusBarIcon asset missing from RunBotResources.bundle — check Assets.xcassets/StatusBarIcon.imageset (see issue #2138)")
        #endif
        return NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil)
            ?? NSImage()
    }

    /// Logical (point) size the icon renders at in the menu bar, regardless
    /// of which @Nx pixel representation AppKit picks for the display. 18pt
    /// is the standard macOS menu bar icon convention (22pt bar height minus
    /// a small margin) — previously this rendered at ~16pt (issue: user
    /// reported the icon looked too small relative to surrounding menu bar
    /// icons).
    private static let statusBarIconPointSize = NSSize(width: 18, height: 18)

    /// Cached `StatusBarIcon` image, loaded from `RunBotResources.bundle` exactly once.
    ///
    /// - Important: `swift build` (the plain SwiftPM CLI toolchain used by
    ///   `build.sh`, as opposed to `xcodebuild`) does **not** run `actool` to
    ///   compile `Assets.xcassets` into `Assets.car`. It just copies the whole
    ///   `.xcassets` folder into the resource bundle verbatim, as a plain
    ///   subdirectory tree. Confirmed by direct runtime inspection during the
    ///   #2079 follow-up investigation: `RunBotResources.bundle`'s top-level
    ///   directory listing contained only `["Assets.xcassets"]` — no `Assets.car`,
    ///   no flattened/extracted PNGs at the bundle root.
    ///
    ///   This is why both `NSImage(named:)` (searches Bundle.main's asset
    ///   catalog machinery, which needs a compiled `.car`) and
    ///   `Bundle.module.image(forResource:)` / `path(forResource:ofType:)`
    ///   (flat, bundle-root-only lookups) returned `nil` — none of them know
    ///   to look three directories deep, inside
    ///   `Assets.xcassets/StatusBarIcon.imageset/`, for a scale-suffixed file.
    ///
    ///   The fix: build the path into the `.imageset` folder explicitly and
    ///   load each `@Nx` PNG directly by literal path, as raw
    ///   `NSBitmapImageRep`s combined into one `NSImage`. This bypasses
    ///   asset-catalog/named-image lookup entirely, so it works the same
    ///   whether or not the catalog was ever compiled.
    ///
    /// - Important: loading a raw PNG this way (instead of through a
    ///   compiled catalog) means AppKit has no `Contents.json` telling it
    ///   each representation's logical point size — an `NSBitmapImageRep`
    ///   built from an `@3x` (54×54px) file defaults its `.size` to 54×54
    ///   *points*, not 18×18, which is 3x too large on screen. Each rep's
    ///   `.size` is explicitly forced to `statusBarIconPointSize` above to
    ///   correct for this.
    ///
    /// - Note: `RunBotResources.bundle` returns the same bundle instance on
    ///   every call (it is a `static nonisolated let`), so caching here as a
    ///   `static let` is still correct for the NSBitmapImageRep cost, not for
    ///   repeated bundle lookups.
    private static let statusBarIcon: NSImage? = {
        // Loads every @Nx PNG that exists (1x/2x/3x) as a representation of
        // a single NSImage, so AppKit can pick the sharpest one for the
        // current screen automatically — same behavior an asset catalog
        // would give us via Contents.json, which literal-path loading
        // doesn't provide on its own.
        let imagesetDir = "Assets.xcassets/StatusBarIcon.imageset"
        let combinedIcon = NSImage(size: statusBarIconPointSize)
        var loadedAny = false

        for scale in [1, 2, 3] {
            let filename = scale == 1 ? "StatusBarIcon" : "StatusBarIcon@\(scale)x"
            guard let path = RunBotResources.bundle.path(forResource: filename, ofType: "png", inDirectory: imagesetDir),
                  let data = NSData(contentsOfFile: path),
                  let rep = NSBitmapImageRep(data: data as Data) else {
                continue
            }
            rep.size = statusBarIconPointSize  // logical size in points, independent of the rep's pixel dimensions
            combinedIcon.addRepresentation(rep)
            loadedAny = true
        }

        guard loadedAny else {
            #if DEBUG
            assertionFailure(
                "StatusBarIcon asset missing from \(imagesetDir) in RunBotResources.bundle"
                + " — check Sources/RunBot/Resources/Assets.xcassets/StatusBarIcon.imageset (see issue #2138)"
            )
            #endif
            return nil
        }

        combinedIcon.isTemplate = true  // belt-and-suspenders on top of Contents.json
        return combinedIcon
    }()
}
