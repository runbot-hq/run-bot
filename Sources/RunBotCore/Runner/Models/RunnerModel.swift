// RunnerModel.swift
// RunBotCore
//
// Locally-discovered GitHub Actions self-hosted runner, found by scanning
// LaunchAgent plists in ~/Library/LaunchAgents. Enriched with GitHub API
// data by RunnerStatusEnricher after discovery.
// See: RunnerStatusEnricher, Runner, RunnerStatus
import Foundation

// MARK: - RunnerModel

/// Represents a locally-installed GitHub Actions self-hosted runner.
///
/// Discovered by scanning LaunchAgent plists in `~/Library/LaunchAgents`.
/// After discovery, `RunnerStatusEnricher` enriches each model with live
/// GitHub API data (`githubStatus`, `isBusy`, `labels`, `runnerGroup`).
///
/// - Note: Distinct from `Runner`, which is the API-fetched remote runner snapshot.
///   `RunnerModel` is local-first; `Runner` is API-first.
/// - Note: Fully `Sendable` because all previously-mutable `var` properties
///   have been converted to `let`. Mutations now go through `copying(…)` which
///   returns a new value — no in-place mutation means no shared-mutable-state
///   data race, and the compiler can synthesise `Sendable` conformance without
///   an `@unchecked` escape hatch.
/// - SeeAlso: `Runner`, `RunnerStatus`, `RunnerStatusEnricher`, `LocalRunnerStore`
public struct RunnerModel: Sendable, Identifiable, Equatable {
    // MARK: Stored Properties

    /// String-based ID so `LocalRunnerStore` can use `runnerName` as the dedup key.
    public let id: String
    /// The human-readable name of the runner as configured on the host machine.
    public let runnerName: String
    /// Absolute path to the runner agent installation directory on disk.
    public let installPath: String?
    /// The GitHub URL scope this runner is registered to (repo or org URL).
    /// Use `copying(gitHubUrl:)` to produce an updated value.
    public let gitHubUrl: URL?
    /// GitHub's internal numeric agent ID for this runner.
    ///
    /// Read from the `.runner` JSON `AgentId` field during local discovery.
    /// For **org-scoped runners** this value can differ from the numeric `id`
    /// that the GitHub REST API returns for the same runner — use `apiId` for
    /// the API-side integer and `agentId` for the locally-stored one.
    public let agentId: Int?
    /// The GitHub REST API numeric runner ID, as returned by the
    /// `/repos/{owner}/{repo}/actions/runners` or `/orgs/{org}/actions/runners`
    /// endpoints.
    ///
    /// Populated by `RunnerStatusEnricher.applyEnrichment` after the first
    /// enrichment cycle. `nil` until enrichment has run at least once.
    ///
    /// Used by `RunnerStore.buildInstallPathMap` to build the `byApiId` lookup
    /// map so that metrics can be matched for org runners whose local `agentId`
    /// does not match the GitHub API id.
    public let apiId: Int?
    /// Absolute path to the runner's `_work` folder on disk.
    public let workFolder: String?
    /// Labels registered for this runner (e.g. `["self-hosted", "macOS", "arm64"]`).
    public let labels: [String]

    // MARK: - Fields from .runner JSON (#491)

    /// Operating system string from `.runner` JSON `platform` key (e.g. `"linux"`, `"osx"`).
    public let platform: String?
    /// Architecture from `.runner` JSON `platformArchitecture` key (e.g. `"X64"`, `"ARM64"`).
    public let platformArchitecture: String?
    /// Agent version string from `.runner` JSON `agentVersion` key (e.g. `"2.320.0"`).
    public let agentVersion: String?
    /// Whether the runner was registered as ephemeral from `.runner` JSON `ephemeral` key.
    public let isEphemeral: Bool
    /// GitHub runner group name. Populated by `RunnerStatusEnricher` via the GitHub API.
    public let runnerGroup: String?

    // TODO: Rename `isRunning` to `isServiceRunning` to clarify that this is
    // the local LaunchAgent/process state, not the remote GitHub runner status.
    /// Launchctl / process running state.
    /// Use `copying(isRunning:)` to produce an updated value.
    public let isRunning: Bool

    /// GitHub API-reported connectivity status. Set by `RunnerStatusEnricher`.
    ///
    /// `nil` when the runner has not yet been enriched or the API call failed.
    public let githubStatus: RunnerStatus?

    /// Whether the runner is currently executing a job. Set by `RunnerStatusEnricher`.
    public let isBusy: Bool

    /// Short error string surfaced directly in the runner row after a failed lifecycle action.
    ///
    /// When non-nil, `displayStatus` shows this string instead of the normal status
    /// so the user sees the problem directly in the row.
    /// Cleared automatically the next time `refresh()` replaces the runner array.
    public let lifecycleWarning: String?

    /// CPU/memory utilisation from the local `ps aux` snapshot, matched by `installPath`.
    ///
    /// `nil` if no matching process was found for this runner, or the runner is not busy.
    /// Populated by `LocalRunnerStore.refresh()` after scanning.
    public let metrics: RunnerMetrics?

    // MARK: - Init

    // NOSONAR — 18 parameters faithfully model the GitHub API runner payload; splitting would break all call sites.
    /// Creates a new `RunnerModel` instance.
    ///
    /// - Parameters:
    ///   - id: Stable dedup key. Defaults to `runnerName` when omitted.
    ///   - runnerName: Human-readable runner name.
    ///   - gitHubUrl: GitHub scope URL (repo or org). May be patched post-init.
    ///   - agentId: GitHub internal numeric agent ID (from `.runner` JSON).
    ///   - apiId: GitHub REST API numeric runner ID (from enrichment). `nil` until enriched.
    ///   - workFolder: Absolute path to the runner `_work` folder.
    ///   - installPath: Absolute path to the runner installation directory.
    ///   - isRunning: Whether the runner agent process is currently running.
    ///   - labels: Registered runner labels.
    ///   - githubStatus: GitHub API connectivity status. `nil` until enriched.
    ///   - isBusy: Whether the runner is executing a job.
    ///   - lifecycleWarning: Optional error string shown in the runner row.
    ///   - platform: OS platform string from `.runner` JSON.
    ///   - platformArchitecture: Architecture string from `.runner` JSON.
    ///   - agentVersion: Agent version string from `.runner` JSON.
    ///   - isEphemeral: Whether the runner is registered as ephemeral.
    ///   - runnerGroup: Runner group name from the GitHub API.
    ///   - metrics: Optional CPU/memory snapshot from `ps aux`.
    public init(
        id: String? = nil,
        runnerName: String,
        gitHubUrl: URL?,
        agentId: Int?,
        apiId: Int? = nil,
        workFolder: String?,
        installPath: String?,
        isRunning: Bool,
        labels: [String] = [],
        githubStatus: RunnerStatus? = nil,
        isBusy: Bool = false,
        lifecycleWarning: String? = nil,
        platform: String? = nil,
        platformArchitecture: String? = nil,
        agentVersion: String? = nil,
        isEphemeral: Bool = false,
        runnerGroup: String? = nil,
        metrics: RunnerMetrics? = nil
    ) {
        self.id = id ?? runnerName
        self.runnerName = runnerName
        self.gitHubUrl = gitHubUrl
        self.agentId = agentId
        self.apiId = apiId
        self.workFolder = workFolder
        self.installPath = installPath
        self.isRunning = isRunning
        self.labels = labels
        self.githubStatus = githubStatus
        self.isBusy = isBusy
        self.lifecycleWarning = lifecycleWarning
        self.platform = platform
        self.platformArchitecture = platformArchitecture
        self.agentVersion = agentVersion
        self.isEphemeral = isEphemeral
        self.runnerGroup = runnerGroup
        self.metrics = metrics
    }

    // MARK: - Private state resolution

    /// Unified display state resolved from all contributing fields.
    ///
    /// Single source of truth consumed by both `displayStatus` and `statusColor`,
    /// eliminating the need to keep two independent conditional trees in sync.
    ///
    /// - Note: Evaluated in priority order: lifecycle warning → local running
    ///   state → GitHub API status.
    /// - Note: `.running` and `.githubOnline` are deliberately distinct cases:
    ///   `.running` means the local agent process is up (green dot);
    ///   `.githubOnline` means the process is *not* running locally but GitHub
    ///   still reports it as reachable (yellow dot). Collapsing these two cases
    ///   would silently break dot-colour semantics.
    private var resolvedState: ResolvedState {
        if lifecycleWarning != nil { return .warning }
        if isRunning { return (isBusy || githubStatus == .busy) ? .busy : .running }
        switch githubStatus {
        case .online: return .githubOnline
        case .busy: return .busy
        default: return .offline
        }
    }

    /// The possible display states used internally by `displayStatus` and `statusColor`.
    private enum ResolvedState {
        /// A lifecycle action failed; `lifecycleWarning` holds the error string.
        case warning
        /// Runner is local-process-running and executing a job.
        case busy
        /// Runner is local-process-running but not executing a job.
        case running
        /// Runner is not running locally but the GitHub API reports it as online.
        ///
        /// Distinct from `.running`: the local agent process is absent, so the
        /// dot colour is yellow (idle) rather than green (active process).
        case githubOnline
        /// Runner is offline from GitHub's perspective and not running locally.
        case offline
    }

    // MARK: - Derived display

    /// Human-readable status label shown in the settings runner row.
    ///
    /// When a lifecycle warning is set it takes priority over the normal status.
    /// - `"busy"` — runner is running and executing a job (#773).
    /// - `"running"` — runner process is up but not executing a job.
    /// - `"online"` — runner is not running locally but GitHub reports it online.
    /// - `"offline"` — runner is not reachable.
    public var displayStatus: String {
        switch resolvedState {
        case .warning: return lifecycleWarning!  // resolvedState only reaches .warning when lifecycleWarning != nil
        case .busy: return "busy"
        case .running: return "running"
        case .githubOnline: return "online"
        case .offline: return "offline"
        }
    }

    /// Dot colour category used by `SettingsView.localRunnerDotColor(for:)`.
    public var statusColor: StatusColor {
        switch resolvedState {
        case .warning: return .offline
        case .busy: return .busy
        case .running: return .running
        case .githubOnline: return .idle
        case .offline: return .offline
        }
    }

    /// Dot colour categories for the runner status indicator.
    public enum StatusColor {
        /// Runner process is up and not busy.
        case running
        /// Runner is executing a job.
        case busy
        /// Runner is not running locally but online per GitHub.
        case idle
        /// Runner is offline or a lifecycle error occurred.
        case offline
    }
}

// MARK: - Copying

/// Provides a `copying(…)` method for producing modified `RunnerModel` values.
extension RunnerModel {
    /// Returns a new `RunnerModel` with selected fields replaced.
    ///
    /// Pass only the fields you want to change; all others are forwarded unchanged.
    /// Uses `Optional<Optional<T>>` (double-optional) for nullable fields so callers
    /// can distinguish "set to nil" (`.some(nil)`) from "leave unchanged" (`.none`).
    ///
    /// `apiId` is intentionally not a parameter — it is set once by
    /// `RunnerStatusEnricher.applyEnrichment` via `init` and must not be
    /// overwritten by any other code path. It is always forwarded as-is.
    ///
    /// Example:
    /// ```swift
    /// runners[idx] = runners[idx].copying(isRunning: true)
    /// let noWarning: String? = nil
    /// runners[idx] = runners[idx].copying(lifecycleWarning: noWarning)  // clears warning — a bare `nil` literal would be a no-op
    /// ```
    public func copying(
        gitHubUrl: URL?? = nil,
        isRunning: Bool? = nil,
        githubStatus: RunnerStatus?? = nil,
        isBusy: Bool? = nil,
        lifecycleWarning: String?? = nil,
        runnerGroup: String?? = nil,
        metrics: RunnerMetrics?? = nil
    ) -> RunnerModel {
        RunnerModel(
            id: id,
            runnerName: runnerName,
            gitHubUrl: gitHubUrl ?? self.gitHubUrl,
            agentId: agentId,
            apiId: apiId,
            workFolder: workFolder,
            installPath: installPath,
            isRunning: isRunning ?? self.isRunning,
            labels: labels,
            githubStatus: githubStatus ?? self.githubStatus,
            isBusy: isBusy ?? self.isBusy,
            lifecycleWarning: lifecycleWarning ?? self.lifecycleWarning,
            platform: platform,
            platformArchitecture: platformArchitecture,
            agentVersion: agentVersion,
            isEphemeral: isEphemeral,
            runnerGroup: runnerGroup ?? self.runnerGroup,
            metrics: metrics ?? self.metrics
        )
    }
}
