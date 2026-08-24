// JobStatus.swift
// RunBotCore
//
// Typed enum for the GitHub Actions job/workflow status field.
// Uses an unknown(String) fallback for forward-compatibility with new API values.
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
