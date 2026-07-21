// RunnerState.swift
// RunBotCore
import AppUpdater
import Foundation
import GitHubClient
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
/// The auto-update storage properties (`availableUpdate`, `cachedUpdateVersion`,
/// `updateActionFailed`, `currentPhase`) are written exclusively by `AppUpdater`
/// via `UpdateStateProviding.apply(_:)`, declared in `RunnerState+AppUpdater.swift`.
@Observable
@MainActor
public final class RunnerState {

    // MARK: - Poll-written runner state (pushed by RunnerPoller)

    /// The current list of GitHub self-hosted runners for all active scopes.
    public internal(set) var runners: [GitHubRunner] = []

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
    ///
    /// `internal(set)` — not `private(set)` — because Swift's `private` is
    /// file-scoped: the setter must be visible to `apply(_:)` in
    /// `RunnerState+AppUpdater.swift`, which is a different file. Moving stored
    /// properties into the extension file is non-standard and was rejected.
    /// The invariant (only `apply(_:)` may write these) is enforced by
    /// convention; see `currentPhase` warning comment in that file.
    public internal(set) var availableUpdate: String?

    /// Version string of the cached update zip, or `nil` if none cached.
    ///
    /// `internal(set)` for the same reason as `availableUpdate` above —
    /// `private(set)` would make the setter inaccessible across file boundaries.
    public internal(set) var cachedUpdateVersion: String?

    /// `true` when a download or install attempt has failed.
    ///
    /// `internal(set)` for the same reason as `availableUpdate` above —
    /// `private(set)` would make the setter inaccessible across file boundaries.
    public internal(set) var updateActionFailed: Bool = false

    /// The current update phase, derived from the raw storage fields above and
    /// kept in sync by `apply(_:)` in `RunnerState+AppUpdater.swift`.
    ///
    /// ## Why this is a stored property, not a computed one
    ///
    /// The `@Observable` macro only instruments *stored* properties. A computed
    /// `currentPhase` is never directly registered with the observation system,
    /// so SwiftUI views that access `runnerState.currentPhase` are never
    /// invalidated when `availableUpdate` or `cachedUpdateVersion` change —
    /// the update row stays hidden after a beta-channel toggle even though the
    /// underlying data changed.
    ///
    /// Promoting it to a stored `var` means the macro tracks it directly.
    /// `apply(_:)` assigns `self.currentPhase = derivedPhase(for:)` at the end
    /// of every phase transition, so it is always consistent with the raw fields.
    ///
    /// `internal(set)` for the same file-scope reason as the other auto-update
    /// properties above — only `apply(_:)` writes it in practice.
    public internal(set) var currentPhase: UpdatePhase = .idle
}
