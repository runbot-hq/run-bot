// NotificationMode.swift
// RunBotCore

/// The set of workflow-result events for which RunBot sends notifications.
public enum NotificationMode: String, CaseIterable, Sendable {
    /// Notify for both successes and failures.
    case all
    /// Notify only when a job fails.
    case failuresOnly
    /// Notify only when a job succeeds.
    case successesOnly
    /// Never send notifications.
    case never

    /// Human-readable label shown in the Settings picker.
    public var label: String {
        switch self {
        case .all:           return "All"
        case .failuresOnly:  return "Failures only"
        case .successesOnly: return "Successes only"
        case .never:         return "Never"
        }
    }
}
