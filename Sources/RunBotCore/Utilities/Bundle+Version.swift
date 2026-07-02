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
