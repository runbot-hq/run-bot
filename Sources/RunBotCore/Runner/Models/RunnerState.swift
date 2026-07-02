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
/// The auto-update storage properties (`availableUpdate`,
/// `cachedUpdateVersion`, `updateActionFailed`) are written
/// exclusively by `AppUpdater` via `UpdateStateProviding.apply(_:)`, declared in
/// `RunnerState+AppUpdater.swift`.
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
    public internal(set) var isRateLimited = false

    /// The date at which the rate limit resets, if currently rate-limited.
    public internal(set) var rateLimitResetDate: Date?

    /// The most recent fetch error, or `nil` if the last fetch succeeded.
    public internal(set) var fetchError: (any Error)?

    // MARK: - Local runner state (pushed by LocalRunnerStore)

    /// Locally-installed runner agents discovered on this Mac.
    public var localRunners: [RunnerModel] = []

    /// `true` while `LocalRunnerStore` is running a refresh cycle.
    public var isLocalScanning: Bool = false

    /// The overall connectivity state of the runner fleet, derived from `runners`.
    public var aggregateStatus: AggregateStatus {
        AggregateStatus(runners: runners)
    }

    // MARK: - Init

    /// Creates a default-initialised `RunnerState` with all properties at their zero values.
    public init() {}

    // MARK: - Auto-update storage (written via UpdateStateProviding.apply(_:))

    /// The latest available version string, or `nil` if up to date / idle.
    ///
    /// Written exclusively by `AppUpdater` via `apply(_:)` in
    /// `RunnerState+AppUpdater.swift`. Read by views to show the update label.
    public internal(set) var availableUpdate: String?

    /// Version string of the cached update zip, or `nil` if none cached.
    public internal(set) var cachedUpdateVersion: String?

    /// `true` when a download or install attempt has failed.
    public internal(set) var updateActionFailed: Bool = false
}
