// JobStatus.swift
// RunBotCore
//
// Typed enums for the GitHub Actions job/workflow status and conclusion fields.
// Both use an unknown(String) fallback for forward-compatibility with new API values.
// See: ActiveJob, WorkflowActionGroup, PollResultBuilder
import Foundation

// MARK: - JobStatus

/// The lifecycle status of a GitHub Actions job or workflow run.
public enum JobStatus: Hashable, Sendable {
    /// Job is waiting to be picked up by a runner.
    case queued
    /// Job is currently executing on a runner.
    case inProgress
    /// Job has finished (see `JobConclusion` for the outcome).
    case completed
    /// Job is waiting on a required approval or environment protection rule.
    case waiting
    /// Job has been requested but not yet queued.
    case requested
    /// Job is pending deployment to a protected environment.
    case pending
    /// A status value not recognised at compile time.
    ///
    /// - Note: Acts as a forward-compatible fallback so new GitHub API status
    ///   values do not cause a decode failure or break polling logic.
    case unknown(String)

    /// The raw string value as returned by the GitHub API.
    public var rawValue: String {
        switch self {
        case .queued: return "queued"
        case .inProgress: return "in_progress"
        case .completed: return "completed"
        case .waiting: return "waiting"
        case .requested: return "requested"
        case .pending: return "pending"
        case .unknown(let raw): return raw
        }
    }

    /// Initialises from a raw API string. Unknown values map to `.unknown(raw)`.
    ///
    /// - Parameter raw: The raw string value as returned by the GitHub REST API.
    public init(rawString raw: String) {
        switch raw {
        case "queued": self = .queued
        case "in_progress": self = .inProgress
        case "completed": self = .completed
        case "waiting": self = .waiting
        case "requested": self = .requested
        case "pending": self = .pending
        default: self = .unknown(raw)
        }
    }

    /// Returns `true` when the job or run is still active (not yet completed).
    ///
    /// - Note: `.unknown` is treated as **inactive** to avoid polling indefinitely
    ///   if GitHub introduces a new status value this client does not yet recognise.
    ///   Erring on the side of stopping the poll is safer than a stuck spinner.
    ///   This is consistent with `WorkflowActionGroup.groupStatus`, which falls
    ///   through to `.completed` whenever no run is `.inProgress` or `.queued` —
    ///   an `.unknown` status run is therefore implicitly treated as completed there too.
    public var isActive: Bool {
        switch self {
        case .queued, .inProgress, .waiting, .requested, .pending: return true
        case .completed, .unknown: return false
        }
    }
}

/// `Codable` conformance for `JobStatus` — encodes and decodes as a plain string.
extension JobStatus: Codable {
    /// Decodes from a single-value string container.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobStatus(rawString: raw)
    }

    /// Encodes as a single-value string container.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `CustomStringConvertible` conformance for `JobStatus`.
extension JobStatus: CustomStringConvertible {
    /// Returns the raw API string value.
    public var description: String { rawValue }
}

/// `ExpressibleByStringLiteral` conformance for `JobStatus` — supports test literals.
extension JobStatus: ExpressibleByStringLiteral {
    /// Initialises from a string literal. Delegates to `init(rawString:)`.
    public init(stringLiteral value: String) {
        self = JobStatus(rawString: value)
    }
}

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

    /// Returns `true` for terminal failure-like conclusions that should trigger alerts
    /// and display the failure badge.
    ///
    /// **Inclusion rationale:**
    /// - `.failure` — a step explicitly failed.
    /// - `.timedOut` — the job exceeded its configured timeout; always actionable.
    /// - `.startupFailure` — the runner itself failed to initialise; indicates
    ///   infrastructure problems that need attention.
    /// - `.actionRequired` — a required check (e.g. a code-scanning tool) determined
    ///   that manual review is needed before the run can be considered passing.
    ///   Intentionally treated as a failure so the badge and failure hook both fire,
    ///   prompting the developer to act. If your workflow uses `action_required` for
    ///   routine deployment approvals and you find this noisy, introduce a separate
    ///   predicate at the call site rather than removing it here.
    ///
    /// **Exclusion rationale:**
    /// - `.cancelled` — user-initiated or triggered by a superseding push; not a CI error.
    /// - `.skipped` — dependency-driven, controlled by `if:` conditions; informational.
    /// - `.neutral` — inconclusive outcome with no definitive pass/fail signal;
    ///   same class as `.skipped`: informational, not actionable.
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
