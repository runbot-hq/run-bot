// AppUpdater.swift
// AppUpdater
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - AppUpdater

/// Drives the in-app auto-update flow: GitHub Releases poll → semver compare →
/// zip download → SHA-256 verification → host-state mutation → install &
/// relaunch on user confirmation.
///
/// `AppUpdater` is a configurable `@MainActor` class carrying no host-specific
/// state of its own beyond what the caller injects. All UI-facing state lives
/// in a caller-supplied `any UpdateStateProviding`; the single cached zip lives
/// at a fixed path derived from `schedulerIdentifier`.
///
/// ## Isolation model
///
/// The class is `@MainActor`, so `isInstalling` and the scheduler reference are
/// race-free without extra locking. The blocking work runs off the main thread
/// regardless: `URLSession` downloads suspend rather than block, checksum
/// verification runs in the `@concurrent` `verifyChecksum` free function, and
/// subprocess launches run in the `@concurrent` `runCommand` helper.
///
/// ## Typical usage
///
/// ```swift
/// let updater = AppUpdater(
///     repo: "your-org/your-repo",
///     currentVersion: "1.2.3",
///     assetName: { _ in "YourApp.zip" },
///     schedulerIdentifier: "com.your-org.update-check",
///     betaChannelProvider: { UserDefaults.standard.bool(forKey: "betaChannel") }
/// )
/// await updater.checkAndHandle(state: myState)
/// updater.scheduleBackgroundCheck(state: myState)
/// ```
@MainActor
public final class AppUpdater {

    // MARK: - Public configuration

    /// `"owner/name"` GitHub repository slug polled for releases.
    public let repo: String

    /// The running app's version (full semver incl. any pre-release suffix).
    public let currentVersion: String

    /// Reverse-DNS identifier for the background scheduler; also used to scope
    /// this updater's cache directory under `~/Library/Caches`.
    ///
    /// Must not be empty and must not contain `/` — both are enforced by
    /// `precondition` at init time.
    public let schedulerIdentifier: String

    // MARK: - Internal configuration

    /// Maps a release tag name to the expected zip asset filename.
    let assetName: @Sendable (String) -> String

    /// Reads the host's current beta-channel preference.
    let betaChannelProvider: @MainActor () -> Bool

    /// The release-fetch abstraction. Defaults to `GitHubReleaseProvider()`.
    let provider: any ReleaseProvider

    // MARK: - Fixed zip URL

    /// The single fixed on-disk destination for the cached update zip.
    ///
    /// All update cycles write to this same path — no version-stamped filenames,
    /// no accumulation of old zips. The file is at:
    /// `~/Library/Caches/<schedulerIdentifier>/update.zip`
    ///
    /// Because the path is fixed, `purgeStaleZips` is no longer needed and
    /// `UserDefaults` is no longer used for zip-path persistence. The zip either
    /// exists at this path (install affordance available) or it doesn't (check
    /// + download needed).
    ///
    /// ## Why this is a computed property, not a `lazy let`
    ///
    /// `fixedZipURL` re-evaluates `FileManager` on every access. This is
    /// intentional: if `cachesDirectory` is transiently unavailable, subsequent
    /// accesses retry caches rather than permanently baking in the `/tmp`
    /// fallback (which a `lazy let` computed at `init` time would do).
    ///
    /// A `lazy var` would compute the path once at `init` time — but `init` runs
    /// synchronously on `@MainActor` and `FileManager.url(for:create:true)` can
    /// block. More critically, a `cachesDirectory` failure at init time would bake
    /// the `/tmp` fallback permanently for the session with no retry possible.
    /// The computed property retries on every access, so a transient failure
    /// self-heals on the next scheduler cycle.
    ///
    /// ## ✅ Single-snapshot rule — do not call this twice in one operation
    ///
    /// Any call site that needs this URL for more than one step MUST snapshot
    /// it once into a local `let` and use that local for all subsequent steps.
    /// `handle()` does this: `let zipURL = fixedZipURL` — the same `zipURL`
    /// is used for the step-1 existence check AND passed as `destination` into
    /// `downloadUpdate`. This guarantees both operations target the exact same
    /// path even if `cachesDirectory` availability changes between calls.
    ///
    /// Do NOT call `fixedZipURL` at multiple points in the same logical
    /// operation — the two calls are not guaranteed to return the same base
    /// directory if the caches directory flips between available and unavailable.
    var fixedZipURL: URL {
        // Re-evaluated on every access by design — see doc comment above.
        let caches: URL
        if let url = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            caches = url
        } else {
            // ⚠️ cachesDirectory unavailable — zip lands in /tmp and may be evicted
            // by the OS before the user taps Install & Relaunch, producing a
            // confusing .failed state with no visible cause. If you see unexpected
            // .failed states in production, check whether ~/Library/Caches is
            // accessible on the affected machine.
            appUpdaterLogger.warning("cachesDirectory unavailable — falling back to temporaryDirectory; zip is evictable and may disappear before install")
            caches = FileManager.default.temporaryDirectory
        }
        return caches
            .appendingPathComponent(schedulerIdentifier, isDirectory: true)
            .appendingPathComponent("update.zip")
    }

    // MARK: - Background check interval

    /// How often `NSBackgroundActivityScheduler` fires a background update check.
    ///
    /// - **Release:** 24 hours.
    /// - **DEBUG:** 60 seconds, overridable per-test.
    #if DEBUG
    /// 60-second interval used in DEBUG builds. Override in test setUp for faster
    /// QA cycles. **Always reset in tearDown** — Swift Testing runs tests
    /// concurrently by default and concurrent mutations of this static are a data race.
    ///
    /// `nonisolated(unsafe)` — written once in test setUp before any scheduler
    /// is constructed; no concurrent mutation path exists in practice.
    nonisolated(unsafe) public static var checkInterval: TimeInterval = 60
    #else
    /// 24-hour interval used in release builds.
    public static let checkInterval: TimeInterval = 24 * 60 * 60
    #endif

    // MARK: - Trust model

    /// When `false`, `installAndRelaunch` verifies that the running bundle and
    /// the downloaded bundle share the same `codesign` `Authority=` identity.
    ///
    /// Default `true` — RunBot's unsigned distribution model relies solely on
    /// the SHA-256 sidecar for integrity.
    public var skipCodeSignValidation: Bool = true

    // MARK: - Runtime flags

    /// `true` while `installAndRelaunch` is mid-flight — guards a double-tap.
    ///
    /// This is the only runtime boolean flag on `AppUpdater` and it will remain
    /// the only one. It is not update state (it is not expressed through
    /// `UpdatePhase`) because it guards execution flow inside the library, not
    /// anything the host needs to observe. Do not add `isChecking`,
    /// `isDownloading`, `isCancelling`, or any other flag. If a proposed feature
    /// requires a new flag, the correct response under Principle 1 is to ask
    /// whether the flag represents a phase transition — if yes, add it to
    /// `UpdatePhase`; if no, the feature is out of scope (Principle 4).
    var isInstalling: Bool = false

    // MARK: - Background scheduler storage

    #if canImport(AppKit)
    /// Retains the `NSBackgroundActivityScheduler` for the app's lifetime.
    ///
    /// Declared `nonisolated(unsafe)` so `deinit` (a nonisolated context) can
    /// call `invalidate()`. All non-deinit accesses are `@MainActor`-isolated.
    nonisolated(unsafe) var activity: NSBackgroundActivityScheduler?
    #endif

    // MARK: - Init / deinit

    /// Creates a configured updater.
    ///
    /// - Parameters:
    ///   - repo: `"owner/name"` GitHub repository slug.
    ///   - currentVersion: The running app's version string.
    ///   - assetName: Maps a tag name to the expected zip asset filename.
    ///   - schedulerIdentifier: Reverse-DNS scheduler id / cache directory name.
    ///     Must not be empty and must not contain `"/"`.
    ///   - betaChannelProvider: Returns the host's beta-channel preference.
    ///   - releaseProvider: The `ReleaseProvider` to use. Defaults to `GitHubReleaseProvider()`.
    public init<P: ReleaseProvider>(
        repo: String,
        currentVersion: String,
        assetName: @escaping @Sendable (String) -> String,
        schedulerIdentifier: String,
        betaChannelProvider: @escaping @MainActor () -> Bool = { false },
        releaseProvider: P = GitHubReleaseProvider()
    ) {
        precondition(!repo.isEmpty, "AppUpdater: repo must not be empty")
        precondition(!schedulerIdentifier.isEmpty, "AppUpdater: schedulerIdentifier must not be empty")
        precondition(
            !schedulerIdentifier.contains("/"),
            "AppUpdater: schedulerIdentifier must not contain '/' — used as a cache directory name component"
        )
        self.repo = repo
        self.currentVersion = currentVersion
        self.assetName = assetName
        self.schedulerIdentifier = schedulerIdentifier
        self.betaChannelProvider = betaChannelProvider
        self.provider = releaseProvider
    }

    deinit {
        #if canImport(AppKit)
        activity?.invalidate()
        #endif
    }
}
