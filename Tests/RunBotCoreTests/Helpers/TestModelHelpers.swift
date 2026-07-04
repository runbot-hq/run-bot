// TestModelHelpers.swift
// RunBotCoreTests
//
// Test-only convenience initialisers for GitHubRunner, GitHubStep, and ActiveJob.
// These helpers exist solely to make test construction concise. They MUST NOT
// be used in production code.
//
// Following the #1935/#1937 refactor, production call sites use the canonical
// names directly: GitHubRunner, GitHubStep, runner.runnerStatus,
// job.jobStatus, job.jobConclusion, job.completedDate, step.stepStatus, etc.
//
// GitHubStep is Decodable-only at the public API surface (internal memberwise
// init in GitHubWorkflowAPI.swift). Tests construct instances via JSON
// round-trip below, using @testable import GitHubClient.

import Foundation
import GitHubClient
@testable import RunBotCore

// MARK: - ActiveJob test convenience inits

extension ActiveJob {
    /// Test-only init: raw `String` status/conclusion — builds the underlying
    /// `GitHubJob` and wraps it.
    init(
        id: Int,
        name: String,
        status: String,
        htmlUrl: String? = nil,
        conclusion: String? = nil,
        isDimmed: Bool = false,
        runnerName: String? = nil,
        scope: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        steps: [GitHubStep] = []
    ) {
        let raw = GitHubJob(
            id: id,
            runID: 0,
            name: name,
            status: status,
            conclusion: conclusion,
            htmlUrl: htmlUrl,
            runnerName: runnerName,
            startedAt: startedAt.map { _testISO8601.string(from: $0) },
            completedAt: completedAt.map { _testISO8601.string(from: $0) },
            createdAt: createdAt.map { _testISO8601.string(from: $0) },
            steps: steps
        )
        self.init(raw: raw, isDimmed: isDimmed, scope: scope)
    }

    /// Test-only init: typed `JobStatus` / `JobConclusion` overload.
    init(
        id: Int,
        name: String,
        status: JobStatus,
        htmlUrl: String? = nil,
        conclusion: JobConclusion? = nil,
        isDimmed: Bool = false,
        runnerName: String? = nil,
        scope: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date? = nil,
        steps: [GitHubStep] = []
    ) {
        self.init(
            id: id, name: name,
            status: status.rawValue,
            htmlUrl: htmlUrl,
            conclusion: conclusion?.rawValue,
            isDimmed: isDimmed,
            runnerName: runnerName,
            scope: scope,
            startedAt: startedAt,
            completedAt: completedAt,
            createdAt: createdAt,
            steps: steps
        )
    }

    // MARK: Property bridges for tests that read the old names

    /// Test bridge: typed effective status.
    var status: JobStatus { jobStatus }
    /// Test bridge: typed effective conclusion.
    var conclusion: JobConclusion? { jobConclusion }
    /// Test bridge: parsed completion date.
    var completedAt: Date? { completedDate }
    /// Test bridge: parsed start date.
    var startedAt: Date? { startDate }
    /// Test bridge: parsed creation date.
    var createdAt: Date? { createdDate }
}

// MARK: - JobStep shim

/// Test-only typealias restoring the pre-refactor `JobStep` name.
typealias JobStep = GitHubStep

extension GitHubStep {
    /// Test-only init: raw String status. Maps the legacy `id` parameter to `number`.
    /// Uses a JSON round-trip because `GitHubStep`'s memberwise init is internal.
    init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        number: Int = 0
    ) {
        let n = id != 0 ? id : number
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        let startJSON     = startedAt.map   { "\"\(_testISO8601.string(from: $0))\"" } ?? "null"
        let endJSON       = completedAt.map { "\"\(_testISO8601.string(from: $0))\"" } ?? "null"
        let json = """
        {"number":\(n),"name":\"\(name)\","status":\"\(status)\","conclusion":\(conclusionJSON),"started_at":\(startJSON),"completed_at":\(endJSON)}
        """
        self = try! JSONDecoder().decode(GitHubStep.self, from: Data(json.utf8))
    }

    /// Test-only init: typed `JobStatus` / `JobConclusion` overload.
    init(
        id: Int,
        name: String,
        status: JobStatus,
        conclusion: JobConclusion? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        number: Int = 0
    ) {
        self.init(
            id: id, name: name,
            status: status.rawValue,
            conclusion: conclusion?.rawValue,
            startedAt: startedAt,
            completedAt: completedAt,
            number: number
        )
    }

    // MARK: Property bridges
    var statusTyped: JobStatus { stepStatus }
    var conclusionTyped: JobConclusion? { stepConclusion }
}

// MARK: - GitHubRunner test convenience init

/// Test-only typealias restoring the pre-refactor `Runner` name.
typealias Runner = GitHubRunner

extension GitHubRunner {
    /// Test-only convenience init: builds a `GitHubRunner` from a typed `RunnerStatus`
/// and optional `busy` flag via JSON round-trip.
/// `GitHubRunner` has no public memberwise init and `labels` is `[GitHubRunnerLabel]`,
/// not `[String]`, so JSON is the only stable construction path from tests.
/// Labels default to empty. Use `displayStatus(metrics:)` at the call site — metrics are not stored on
/// `GitHubRunner`.
init(id: Int, name: String, status: RunnerStatus, busy: Bool = false, metrics: RunnerMetrics? = nil) {
    let json = """
    {"id":\(id),"name":\"\(name)\",\"status\":\"\(status.rawValue)\",\"busy\":\(busy ? "true" : "false"),"labels":[]}
    """

        self = try! JSONDecoder().decode(GitHubRunner.self, from: Data(json.utf8))
    }

    /// Convenience forwarder for tests that call `runner.displayStatus` without args.
    var displayStatus: String { displayStatus(metrics: nil) }
}

// MARK: - Private ISO8601 formatter

nonisolated(unsafe) private let _testISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
