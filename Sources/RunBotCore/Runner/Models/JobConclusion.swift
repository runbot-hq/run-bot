// JobConclusion.swift
// RunBotCore
//
// Typed enum for the GitHub Actions job/workflow conclusion field.
// Uses an unknown(String) fallback for forward-compatibility with new API values.
// See: ActiveJob, WorkflowActionGroup, PollResultBuilder

// MARK: - JobConclusion

/// The outcome of a completed GitHub Actions job or workflow run.
public enum JobConclusion: Hashable, Sendable {
    /// All steps completed successfully.
    case success
    /// One or more steps failed.
    case failure
    /// The job was cancelled by a user or another workflow.
    case cancelled
    /// The job was skipped due to an `if:` condition evaluating to false.
    case skipped
    /// The job exceeded its configured timeout.
    case timedOut
    /// A manual approval is required before the job can proceed.
    case actionRequired
    /// The job completed without a definitive pass/fail outcome.
    case neutral
    /// The job became stale waiting for an external event.
    case stale
    /// The runner failed to initialise before the job could start.
    case startupFailure
    /// A conclusion value not recognised at compile time.
    ///
    /// - Note: Acts as a forward-compatible fallback so new GitHub API conclusion
    ///   values do not cause a decode failure.
    case unknown(String)

    /// The raw string value as returned by the GitHub API.
    public var rawValue: String {
        switch self {
        case .success: return "success"
        case .failure: return "failure"
        case .cancelled: return "cancelled"
        case .skipped: return "skipped"
        case .timedOut: return "timed_out"
        case .actionRequired: return "action_required"
        case .neutral: return "neutral"
        case .stale: return "stale"
        case .startupFailure: return "startup_failure"
        case .unknown(let raw): return raw
        }
    }

    /// Initialises from a raw API string. Unknown values map to `.unknown(raw)`.
    ///
    /// - Parameter raw: The raw string value as returned by the GitHub REST API.
    public init(rawString raw: String) {
        switch raw {
        case "success": self = .success
        case "failure": self = .failure
        case "cancelled": self = .cancelled
        case "skipped": self = .skipped
        case "timed_out": self = .timedOut
        case "action_required": self = .actionRequired
        case "neutral": self = .neutral
        case "stale": self = .stale
        case "startup_failure": self = .startupFailure
        default: self = .unknown(raw)
        }
    }

    /// Returns `true` for conclusions that represent a terminal, actionable failure.
    ///
    /// **Included:**
    /// - `.failure` — one or more steps explicitly failed.
    /// - `.timedOut` — the job exceeded its configured timeout.
    /// - `.startupFailure` — the runner itself failed to initialise.
    /// - `.actionRequired` — a required check flagged the run as needing manual review.
    ///
    /// **Excluded:**
    /// - `.cancelled` — user-initiated or superseded; not a CI error.
    /// - `.skipped` — controlled by `if:` conditions; informational only.
    /// - `.neutral` — inconclusive; no definitive pass/fail signal.
    public var isFailure: Bool {
        switch self {
        case .failure, .timedOut, .startupFailure, .actionRequired: return true
        default: return false
        }
    }
}

/// `Codable` conformance for `JobConclusion` — encodes and decodes as a plain string.
extension JobConclusion: Codable {
    /// Decodes from a single-value string container.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobConclusion(rawString: raw)
    }

    /// Encodes as a single-value string container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `CustomStringConvertible` conformance for `JobConclusion`.
extension JobConclusion: CustomStringConvertible {
    /// Returns the raw API string value.
    public var description: String { rawValue }
}

/// `ExpressibleByStringLiteral` conformance for `JobConclusion` — supports test literals.
extension JobConclusion: ExpressibleByStringLiteral {
    /// Initialises from a string literal. Delegates to `init(rawString:)`.
    public init(stringLiteral value: String) {
        self = JobConclusion(rawString: value)
    }
}

// MARK: - Notification title

/// `JobConclusion` notification title strings for `UNUserNotificationCenter` dispatch.
extension JobConclusion {
    /// The human-readable notification title for this conclusion.
    ///
    /// Maps each conclusion to an accurate, user-facing label:
    /// - `.success` → "Job succeeded"
    /// - `.failure` → "Job failed"
    /// - `.cancelled` → "Job cancelled"
    /// - `.timedOut` → "Job timed out"
    /// - `.startupFailure` → "Runner failed to start"
    /// - `.actionRequired` → "Job needs review"
    /// - `.skipped` → "Job skipped"
    /// - `.neutral` → "Job completed"
    /// - `.stale` → "Job became stale"
    /// - `.unknown` → "Job completed"
    public var notificationTitle: String {
        switch self {
        case .success: return "Job succeeded"
        case .failure: return "Job failed"
        case .cancelled: return "Job cancelled"
        case .timedOut: return "Job timed out"
        case .startupFailure: return "Runner failed to start"
        case .actionRequired: return "Job needs review"
        case .skipped: return "Job skipped"
        case .neutral: return "Job completed"
        case .stale: return "Job became stale"
        case .unknown: return "Job completed"
        }
    }
}
