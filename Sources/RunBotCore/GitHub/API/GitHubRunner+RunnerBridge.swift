// GitHubRunner+RunnerBridge.swift
// RunBotCore
//
// RunBotCore-layer extensions on GitHubRunner that depend on types
// (RunnerMetrics) which live in RunBotCore, not GitHubClient.
//
// NOTE: runnerStatus and displayStatus(metrics:) now live in
// GitHubRunner+AppExtensions.swift (Step 3). Only copying(metrics:)
// and the GitHubRunnerWithMetrics carrier remain here.

import GitHubClient

// MARK: - Metrics bridge

extension GitHubRunner {
    /// Returns a copy of this runner with the given `metrics` value applied.
    ///
    /// `metrics` is not decoded from the GitHub API — it is populated locally
    /// by `RunnerPoller` after fetching `ps aux` data for busy runners.
    ///
    /// - Parameter metrics: The CPU/memory snapshot to attach. Pass `nil` to clear.
    /// - Returns: A new `GitHubRunner` with the metrics carrier reset; all API fields unchanged.
    public func copying(metrics: RunnerMetrics?) -> GitHubRunner {
        GitHubRunnerWithMetrics(base: self, metrics: metrics).runner
    }
}

// MARK: - Metrics carrier

/// Internal value type that attaches `RunnerMetrics` to a `GitHubRunner`.
///
/// `GitHubRunner` is defined in the `GitHubClient` package and cannot store
/// `RunnerMetrics` (a `RunBotCore` type) directly. This private carrier holds
/// the pair and exposes a convenience `runner` accessor.
///
/// The simpler alternative — a second stored property on `GitHubRunner` — would
/// couple `GitHubClient` to `RunBotCore`, violating the package boundary. This
/// carrier is intentionally `internal` and not part of the public API.
struct GitHubRunnerWithMetrics {
    /// The base runner value carrying the GitHub API fields.
    let base: GitHubRunner
    /// The CPU/memory snapshot to attach, or `nil` to clear metrics.
    let metrics: RunnerMetrics?

    /// Re-exposes the base runner. Metrics are carried separately by `RunnerPoller`.
    var runner: GitHubRunner { base }
}
