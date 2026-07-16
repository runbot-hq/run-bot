// Bundle+Version.swift
// RunBotCore
import AppUpdater
import Foundation

/// Convenience accessors for the running bundle's version string.
extension Bundle {
    /// The full version string for this bundle, read from `RBVersionString`.
    ///
    /// `RBVersionString` is patched by `publish.yml` at build time and preserves
    /// pre-release suffixes (e.g. `0.7.0-beta.1`) that macOS strips from
    /// `CFBundleShortVersionString`. Falls back to `CFBundleShortVersionString`
    /// when `RBVersionString` is absent, bottoming out at `"0.0.0"`.
    ///
    /// ## ⚠️ Dev-build quirk — not a bug
    ///
    /// In a local development build where `publish.yml` has NOT patched
    /// `Info.plist`, `RBVersionString` retains its default value of `"0.7.0"`
    /// from `Info.plist`. Because `"0.7.0"` is older than any release newer
    /// than that baseline, `isOlderThan` will return `true` for any cached
    /// update zip for a version newer than `"0.7.0"` present in
    /// `~/Library/Caches/io.github.runbot-hq.update-check/` from a previous
    /// build on the same machine. This can cause a spurious **Install &
    /// Relaunch** button to appear in Settings → About on a dev machine.
    ///
    /// This is harmless in production — CI always patches `RBVersionString`
    /// via the `Patch Info.plist` step in `publish.yml`. If the spurious button
    /// is annoying during development, delete the cached zip manually:
    ///
    ///     rm ~/Library/Caches/io.github.runbot-hq.update-check/update.zip
    ///
    /// or add `RBVersionString` to your local `Info.plist` with a high version
    /// (e.g. `"99.0.0"`) to suppress all update offers.
    ///
    /// REVIEWER: The `CFBundleShortVersionString` fallback and the `"0.0.0"`
    /// bottom-out are intentional. `rbVersionString` never returns an empty
    /// string, so `checkForUpdate` never returns `.failed(.missingVersionKey)`
    /// when called with `Bundle.main.rbVersionString` — that guard is
    /// unreachable via this property. The `.missingVersionKey` error case
    /// exists for callers that pass a raw version string that may be empty
    /// (e.g. in tests or external consumers). The `"0.0.0"` fallback means a
    /// dev build without a patched Info.plist will always see every real release
    /// as newer — see the dev-build quirk note above.
    public var rbVersionString: String {
        if let versionString = infoDictionary?["RBVersionString"] as? String, !versionString.isEmpty { return versionString }
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Returns `true` when the running bundle is a pre-release build.
    ///
    /// A build is considered pre-release when its `rbVersionString` contains a
    /// hyphenated pre-release identifier, e.g. `0.7.3-beta.14`, `1.0.0-alpha.1`,
    /// or `2.0.0-rc.2`. Stable builds (`1.0.0`, `0.7.3`) return `false`.
    ///
    /// This property is intentionally independent of `AppPreferencesStore.betaChannel`:
    /// the toggle controls *which future updates are offered*; this property describes
    /// *the currently installed binary*. The two answer different questions and must
    /// not be conflated. See issue #2085.
    ///
    /// ## Versioning scheme assumption
    ///
    /// The detection relies on `contains("-")`, which correctly matches this project's
    /// named pre-release identifiers (`-beta.N`, `-alpha.N`, `-rc.N`). Note that a
    /// numeric-only pre-release identifier (e.g. `"1.0.0-0"`, valid per the semver
    /// spec) would also return `true` here. This is not a current concern — the project
    /// does not use numeric-only tags — but if the versioning scheme ever evolves beyond
    /// named identifiers, this implementation should be revisited.
    ///
    /// ## Fallback edge case
    ///
    /// `rbVersionString` has a `CFBundleShortVersionString` middle fallback that macOS
    /// intentionally strips of pre-release suffixes. This means if `RBVersionString` is
    /// absent from `Info.plist` but `CFBundleShortVersionString` is present, a beta build
    /// would return `false` here — a silent false negative. This is a **dev-only** edge
    /// case: CI always patches `RBVersionString` via `publish.yml`, so in production
    /// `rbVersionString` always carries the full semver suffix and `isPreReleaseBuild`
    /// is always accurate. The `"0.0.0"` bottom-out (no hyphen) is also safe — a
    /// completely unpatched dev build returns `false`, which is acceptable.
    ///
    /// ## Usage
    /// ```swift
    /// if Bundle.main.isPreReleaseBuild {
    ///     Text("Pre-release build").font(.caption2)
    /// }
    /// ```
    public var isPreReleaseBuild: Bool {
        rbVersionString.contains("-")
    }

    /// Returns `true` when `version` is strictly newer than the running bundle's
    /// `RBVersionString`.
    ///
    /// Uses the same `ParsedVersion` comparison logic as `UpdateChecker` so beta
    /// ordering is consistent throughout the app.
    ///
    /// ```swift
    /// if Bundle.main.isOlderThan(version: release.version) { … }
    /// ```
    public func isOlderThan(version: String) -> Bool {
        UpdateChecker.isNewer(version, than: rbVersionString)
    }
}
