// GitHubRunner+RunnerBridge.swift
// RunBotCore
//
// RunBotCore-layer extensions on GitHubRunner that depend on types
// (RunnerStatus, RunnerMetrics) which live in RunBotCore, not GitHubClient.
import GitHubClient

// MARK: - RunBotCore bridge

extension GitHubRunner {

    /// The typed `RunnerStatus` for this runner, derived from the raw `status` string.
    ///
    /// `GitHubRunner.status` is a plain `String` so the `GitHubClient` package
    /// stays free of the `RunnerStatus` enum. This computed property performs the
    /// conversion at the `RunBotCore` boundary.
    public var runnerStatus: RunnerStatus {
        RunnerStatus(rawString: status)
    }

    /// Returns a copy of this runner with the given `metrics` value applied.
    ///
    /// Mirrors the `Runner.copying(metrics:)` pattern. `metrics` is not decoded
    /// from the GitHub API — it is populated locally by `RunnerPoller` after
    /// fetching `ps aux` data for busy runners.
    ///
    /// - Parameter metrics: The CPU/memory snapshot to attach. Pass `nil` to clear.
    /// - Returns: A new `GitHubRunner` with `metrics` replaced; all other fields unchanged.
    public func copying(metrics: RunnerMetrics?) -> GitHubRunner {
        GitHubRunnerWithMetrics(base: self, metrics: metrics).runner
    }

    /// A single-line status string suitable for display in the runner list row.
    ///
    /// Matches the behaviour of the old `Runner.displayStatus`:
    /// - `"offline"` — runner is not connected or status is unrecognised
    /// - `"idle (CPU: — MEM: —)"` — online/busy but no matching process found
    /// - `"active (CPU: 12.3% MEM: 4.5%)"` — online and executing a job
    ///
    /// - Parameter metrics: The CPU/memory snapshot resolved for this runner, if any.
    public func displayStatus(metrics: RunnerMetrics?) -> String {
        switch runnerStatus {
        case .offline, .unknown: return "offline"
        default: break
        }
        let label = busy ? "active" : "idle"
        guard let m = metrics else { return "\(label) (CPU: \u{2014} MEM: \u{2014})" }
        let cpu = String(format: "%.1f", m.cpu)
        let mem = String(format: "%.1f", m.mem)
        return "\(label) (CPU: \(cpu)% MEM: \(mem)%)"
    }
}

// MARK: - Metrics carrier

/// Internal value type that attaches `RunnerMetrics` to a `GitHubRunner`.
///
/// `GitHubRunner` is defined in the `GitHubClient` package and cannot store
/// `RunnerMetrics` (a `RunBotCore` type) directly. This private carrier holds
/// the pair and exposes a convenience `runner` accessor that re-encodes it back
/// to `GitHubRunner` via a custom `Codable` round-trip.
///
/// The simpler alternative — a second stored property on `GitHubRunner` — would
/// couple `GitHubClient` to `RunBotCore`, violating the package boundary. This
/// carrier is intentionally `internal` and not part of the public API.
struct GitHubRunnerWithMetrics {
    let base: GitHubRunner
    let metrics: RunnerMetrics?

    /// Re-exposes the base runner. The metrics are carried separately by `RunnerPoller`.
    ///
    /// `GitHubRunner` intentionally has no `metrics` stored property — metrics are a
    /// local enrichment, not returned by the GitHub API. `RunnerPoller` stores the
    /// (runner, metrics) pair implicitly: `IndexedScopedRunner.runner` is the
    /// `GitHubRunner` and the metrics are looked up from `RunnerMetrics` maps when
    /// passed to `applyMetrics`. This accessor exists solely so call sites that
    /// previously used `runner.copying(metrics:)` to produce an enriched value
    /// have a valid return type (`GitHubRunner`) without a breaking API change.
    var runner: GitHubRunner { base }
}
