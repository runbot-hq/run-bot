// AggregateStatus.swift
// RunBotCore
import GitHubClient

// MARK: - AggregateStatus

/// The overall connectivity state of the runner fleet, derived by `RunnerState.aggregateStatus`.
///
/// Drives the status-bar dot colour and the menu-bar SF Symbol:
/// - `allOnline`  → green dot / filled circle  (every runner online or busy)
/// - `someOffline` → yellow dot / half-filled circle (mixed)
/// - `allOffline`  → dark dot  / empty circle   (no runners reachable)
public enum AggregateStatus: Sendable {
    /// Every runner in the fleet is `.online` or `.busy`.
    case allOnline
    /// At least one runner is offline while at least one is online or busy.
    case someOffline
    /// Every runner in the fleet is `.offline` (or the fleet is empty).
    case allOffline

    /// Emoji dot used in the menu-bar title string.
    public var dot: String {
        switch self {
        case .allOnline: return "🟢"
        case .someOffline: return "🟡"
        case .allOffline: return "⚫"
        }
    }

    /// Derives the aggregate status from a fleet of runners.
    ///
    /// - Parameter runners: The current runner list from the GitHub API.
    public init(runners: [GitHubRunner]) {
        guard !runners.isEmpty else { self = .allOffline; return }
        let onlineCount = runners.filter {
            let s = $0.runnerStatus
            return s == .online || s == .busy
        }.count
        if onlineCount == runners.count {
            self = .allOnline
        } else if onlineCount == 0 {
            self = .allOffline
        } else {
            self = .someOffline
        }
    }

    /// SF Symbol name used for the status-bar icon.
    public var symbolName: String {
        switch self {
        case .allOnline: return "circle.fill"
        case .someOffline: return "circle.lefthalf.filled"
        case .allOffline: return "circle"
        }
    }
}
