// RunnerState.swift
// RunBotCore
import Foundation
import Observation

// MARK: - RunnerState

/// Observable read model populated by `RunnerPoller` and consumed by the app layer.
///
/// All mutations happen on the `MainActor`. Views and `AppDelegate` observe this
/// object directly via `withObservationTracking` or `ObservationLoop`.
///
/// The six poll-written properties (`runners`, `jobs`, `actions`, `isRateLimited`,
/// `rateLimitResetDate`, `fetchError`) are `public internal(set)` — only
/// `RunnerPoller.applyFetchResult` (same module) should mutate them.
/// Two additional properties (`localRunners`, `isLocalScanning`) are `public var`
/// because Swift requires the setter to match the accessibility of a `public` protocol
/// `{ get set }` requirement — see `RunnerViewModelProtocol` for the rationale.
/// Only `LocalRunnerStore` (in `RunBotCore`) writes them in practice.
/// The auto-update download properties (`updateZipURL`, `cachedUpdateVersion`,
/// `updateAssetMissing`, `updateActionFailed`) are `public internal(set)` — only
/// `AutoUpdater` (same `RunBotCore` module) writes them via `await MainActor.run`.
/// Views and app-layer code are read-only consumers of all properties.
@Observable
@MainActor
public final class RunnerState {

    // MARK: - Poll-written runner state (pushed by RunnerPoller)

    /// The current list of GitHub self-hosted runners for all active scopes.
    public internal(set) var runners: [Runner] = []

    /// Active and recently-completed jobs across all active scopes.
    public internal(set) var jobs: [ActiveJob] = []

    /// Workflow action groups (runs) across all active scopes.
    public internal(set) var actions: [WorkflowActionGroup] = []

    /// Whether the GitHub API rate limit has been hit.
    ///
    /// When `true`, polling is paused until `rateLimitResetDate`.
    public internal(set) var isRateLimited = false

    /// The date at which the rate limit resets, if currently rate-limited.
    public internal(set) var rateLimitResetDate: Date?

    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    ///
    /// Set by `RunnerPoller.applyError(_:)`; cleared on every successful
    /// `applyFetchResult`. Views read this to show a non-modal error banner.
    ///
    /// Typed `(any Error)?` — the stored value is always a `RunnerPoller.FetchError`,
    /// which is `Sendable`. The property stays `any Error` for display flexibility;
    /// `@MainActor` isolation on `RunnerState` ensures safe cross-actor reads.
    public internal(set) var fetchError: (any Error)?

    // MARK: - Local runner state (pushed by LocalRunnerStore)

    /// Locally-installed runner agents discovered on this Mac.
    ///
    /// Pushed by `LocalRunnerStore` via `await MainActor.run { }` after every refresh cycle.
    ///
    /// Declared `public var` (not `public internal(set) var`) because Swift requires the
    /// setter to be at least as accessible as the protocol requirement when conforming to a
    /// public protocol with a `{ get set }` requirement. `public internal(set)` would restrict
    /// the setter to `RunBotCore` and fail to satisfy the requirement at the module interface.
    /// In practice, only `LocalRunnerStore` (inside `RunBotCore`) ever writes this property;
    /// the `public` setter is a type-system necessity, not an invitation for external mutation.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    ///
    /// Pushed by `LocalRunnerStore` alongside `localRunners`.
    /// See `localRunners` for the access-level rationale.
    public var isLocalScanning: Bool = false

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    /// Observed by `AppDelegate`'s `statusIconLoop` via `ObservationLoop`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    // MARK: - Init

    /// Public memberwise-style initialiser required so that `RunnerPollerProtocol`
    /// can use `RunnerState()` as a default argument value from another module
    /// (`RunBot` app target). Without an explicit `public init()`, the
    /// `@Observable`-synthesised initialiser is `internal` and the cross-module
    /// default argument fails to compile.
    public init() {}

    // MARK: - Auto-update state (pushed by AutoUpdater)

    /// The latest available version string if a newer version exists, or `nil` if
    /// up to date.
    ///
    /// **Read-only for all callers.** Write via `setAvailableUpdate(_:)` below.
    public private(set) var availableUpdate: String?

    /// Sets `availableUpdate`.
    ///
    /// Called from `AutoUpdater.handle(_:state:)` on every `.updateAvailable` result
    /// (including the launch-time check in `AppDelegate+PanelSetup`) and from
    /// `AutoUpdater.scheduleBackgroundCheck` to clear a stale row on `.upToDate`
    /// or `.failed` results (when no zip is cached).
    ///
    /// Using an explicit method (rather than direct property assignment) keeps
    /// every write site visible in code review and prevents ad-hoc mutation elsewhere.
    public func setAvailableUpdate(_ version: String?) {
        availableUpdate = version
    }

    /// Local file URL of the cached `RunBot-update.zip`, or `nil` while the
    /// download is in progress or has not started yet.
    ///
    /// The Install & Relaunch button is shown only when this is non-`nil`.
    public internal(set) var updateZipURL: URL?

    /// Version string of the cached update zip (e.g. `"v0.8.0"`), or `nil`
    /// if no download has been cached yet.
    public internal(set) var cachedUpdateVersion: String?

    /// Rehydrates cached download state from `UserDefaults` on startup.
    ///
    /// Called by `AppDelegate+PanelSetup` after verifying that the cached zip
    /// still exists on disk and the cached version is newer than the installed app.
    public func rehydrateCachedUpdate(zipURL: URL, version: String) {
        updateZipURL = zipURL
        cachedUpdateVersion = version
    }

    /// `true` when the latest release exists but its `RunBot.zip` asset is absent.
    ///
    /// When `true` the UI falls back to a **Download** button that opens the
    /// releases page in the browser instead of triggering an in-app install.
    public internal(set) var updateAssetMissing: Bool = false

    /// `true` when a download **or** an install attempt has failed.
    ///
    /// The Download fallback button is shown whenever
    /// `updateAssetMissing || updateActionFailed`.
    public internal(set) var updateActionFailed: Bool = false
}
