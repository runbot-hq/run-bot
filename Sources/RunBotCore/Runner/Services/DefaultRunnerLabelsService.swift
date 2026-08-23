// DefaultRunnerLabelsService.swift
// RunBotCore
import Foundation
import GitHubClient

// MARK: - DefaultRunnerLabelsService

/// Live conformance of `RunnerLabelsService` that delegates to `patchRunnerLabels`.
///
/// Moved from `RunBot` to `RunBotCore` in #1610 once the original blocker
/// (`patchRunnerLabels` depending on an app-layer transport) was resolved:
/// `GitHubURLSessionTransport` and the `patchRunnerLabels` free function both
/// live in `RunBotCore/GitHub/`.
///
/// Moved from `RunBotCore/Services/` to `RunBotCore/Runner/Services/` because
/// it delegates directly to `patchRunnerLabels` — a runner domain operation — and
/// has no business being alongside Keychain, LogFetcher, and LoginItem.
///
/// Placing this type in Core means the label-patching path is fully testable
/// via `swift test` with a mock `GitHubTransportProtocol` — no simulator,
/// no signing, no entitlements.
public struct DefaultRunnerLabelsService: RunnerLabelsService, Sendable {
    /// Creates a new `DefaultRunnerLabelsService`.
    public init() {
        // Intentionally empty: stateless service holds no stored properties.
    }

    /// Replaces ALL custom labels on the runner identified by `runnerID` within `scope`
    /// by delegating to the `patchRunnerLabels` free function.
    /// - Returns: The updated label names on success, `nil` on any API failure.
    public func patch(scope: String, runnerID: Int, labels: [String]) async -> [String]? {
        await patchRunnerLabels(scope: scope, runnerID: runnerID, labels: labels)
    }
}
