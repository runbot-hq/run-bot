// AutoUpdaterDefaults.swift
// RunBot
import Foundation

// MARK: - AutoUpdaterDefaults

/// `UserDefaults` key constants and scheduler interval for the auto-update flow.
///
/// Keys follow the reverse-DNS bundle identifier prefix so they are namespaced
/// away from any future SDK or system key collisions.
public enum AutoUpdaterDefaults {
    /// `UserDefaults` key for the version string of the cached update zip.
    ///
    /// Written by `AutoUpdater` after a successful download; cleared by
    /// `AppDelegate+PanelSetup` on startup when the cached version is no
    /// longer newer than the installed version.
    public static let cachedUpdateVersion = "io.github.runbot-hq.cachedUpdateVersion"

    /// `UserDefaults` key for the file-system path of the cached update zip.
    ///
    /// Written alongside `cachedUpdateVersion`; cleared under the same conditions.
    public static let cachedUpdateZipPath = "io.github.runbot-hq.cachedUpdateZipPath"

    /// How often `NSBackgroundActivityScheduler` fires a background update check.
    ///
    /// - **Release:** 24 hours. Hard-coded; there is intentionally no UI to
    ///   change this — a daily check is the correct bar for a menu bar utility.
    /// - **DEBUG:** 60 seconds default, overridable per-test so the scheduler
    ///   fires quickly in QA and unit-test scenarios without sleeping.
    ///
    /// The launch-time check in `AppDelegate+PanelSetup` fires immediately on
    /// every startup. The scheduler fires only after the first `checkInterval`
    /// elapses — this is by design, not an oversight.
    #if DEBUG
    /// 60-second interval used in DEBUG builds. Override in tests for faster QA cycles.
    /// - Note: Marked `@MainActor` — test overrides must cross the actor boundary using
    ///   the project's canonical pattern (see `docs/architecture/concurrency-overview.md` Pillar 2):
    ///   `await MainActor.run { AutoUpdaterDefaults.checkInterval = N }`
    @MainActor public static var checkInterval: TimeInterval = 60
    #else
    /// 24-hour interval used in release builds.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    #endif
}
