// GitHubRunner+AppExtensions.swift
// RunBotCore

import GitHubClient

/// RunBotCore-layer extensions on `GitHubRunner` that depend on types
/// (`RunnerStatus`, `RunnerMetrics`) which live in RunBotCore, not GitHubClient.
extension GitHubRunner {
    /// Typed status for UI rendering.
    /// Uses RunnerStatus(rawString:) — NOT init(rawValue:) which does not exist on RunnerStatus.
    public var runnerStatus: RunnerStatus { RunnerStatus(rawString: status) }

    /// Flat label name list for display and filtering.
    public var labelNames: [String] { labels.map(\.name) }

    /// Single-line display string for the runner list row.
    /// Matches the existing Runner.displayStatus format exactly:
    /// "offline" | "idle (CPU: — MEM: —)" | "active (CPU: 12.3% MEM: 4.5%)"
    public func displayStatus(metrics: RunnerMetrics?) -> String {
        switch runnerStatus {
        case .offline, .unknown: return "offline"
        default: break
        }
        let label = busy ? "active" : "idle"
        guard let metrics else { return "\(label) (CPU: \u{2014} MEM: \u{2014})" }
        return "\(label) (CPU: \(String(format: "%.1f", metrics.cpu))% MEM: \(String(format: "%.1f", metrics.mem))%)"
    }
}
