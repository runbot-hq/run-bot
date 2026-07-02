// Bundle+Version.swift
// RunBot
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
    /// `Info.plist`, `RBVersionString` is absent and the fallback chain
    /// returns `"0.0.0"`. Because `"0.0.0"` is older than any real release
    /// version, `isOlderThan` will return `true` for any cached update zip
    /// that happens to be present in `~/Library/Caches/io.github.runbot-hq/`
    /// from a previous release build run on the same machine. This can cause
    /// a spurious **Install & Relaunch** button to appear in Settings → About
    /// on a dev machine.
    ///
    /// This is harmless in production — CI always patches `RBVersionString`
    /// via the `Patch Info.plist` step in `publish.yml`. If the spurious button
    /// is annoying during development, delete the cached zip manually:
    ///
    ///     rm ~/Library/Caches/io.github.runbot-hq/RunBot-*.zip
    ///
    /// or add `RBVersionString` to your local `Info.plist` with a high version
    /// (e.g. `"99.0.0"`) to suppress all update offers.
    ///
    /// REVIEWER: The `CFBundleShortVersionString` fallback and the `"0.0.0"`
    /// bottom-out are intentional. `checkForUpdate` deliberately does NOT use
    /// this fallback (it returns `.failed(.missingVersionKey)` instead) because
    /// offering an update against an unknown base is worse than doing nothing.
    /// The asymmetry is by design — `rbVersionString` is used for display and
    /// cache rehydration only, not as the update gate.
    public var rbVersionString: String {
        if let versionString = infoDictionary?["RBVersionString"] as? String, !versionString.isEmpty { return versionString }
        return infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
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
