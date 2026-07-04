// TestModelHelpers.swift
// RunBotCoreTests
//
// Shims that restore the old ActiveJob / JobStep / Runner convenience initialisers
// for the test suite after the #1935/#1937 GitHubClient extraction refactor.
// These helpers MUST NOT be used in production code.

import Foundation
import GitHubClient
@testable import RunBotCore

// MARK: - ActiveJob test convenience init

extension ActiveJob {
    /// Test-only convenience init matching the pre-refactor ActiveJob memberwise signature
    /// (raw String status/conclusion).
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
        self.init(
            raw: raw,
            isDimmed: isDimmed,
            scope: scope
        )
    }

    /// Test-only convenience init with typed `JobStatus` / `JobConclusion`.
    /// Used by `ActiveJobRBStatusTests`, `ActiveJobAsCompletedTests`, and
    /// `WorkflowActionGroupFetcherTests`.
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
            id: id,
            name: name,
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

    // MARK: Property bridges for tests that read the old property names

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

// MARK: - JobStep shim (typealias + convenience inits)

/// Test-only typealias restoring the pre-refactor `JobStep` name.
typealias JobStep = GitHubStep

extension GitHubStep {
    /// Test-only convenience init: raw String status. Maps `id` → `number`.
    init(
        id: Int,
        name: String,
        status: String,
        conclusion: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        number: Int = 0
    ) {
        self.init(
            name: name,
            status: status,
            conclusion: conclusion,
            number: id != 0 ? id : number,
            startedAt: startedAt.map { _testISO8601.string(from: $0) },
            completedAt: completedAt.map { _testISO8601.string(from: $0) }
        )
    }

    /// Test-only convenience init: typed `JobStatus`. Maps `id` → `number`.
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

// MARK: - GitHubStep memberwise init shim
//
// `GitHubStep` is `Decodable`-only in production. The public memberwise init
// added to `GitHubWorkflowAPI.swift` (number:name:status:conclusion:startedAt:
// completedAt:) is the canonical production path. This extension provides
// the name-only variant for tests that already call `self.init(name:status:...)`.

extension GitHubStep {
    /// Convenience init used by helpers that build steps from raw strings.
    /// Delegates to the public memberwise init on `GitHubStep`.
    init(
        name: String,
        status: String,
        conclusion: String? = nil,
        number: Int,
        startedAt: String? = nil,
        completedAt: String? = nil
    ) {
        self.init(
            number: number,
            name: name,
            status: status,
            conclusion: conclusion,
            startedAt: startedAt,
            completedAt: completedAt
        )
    }
}

// MARK: - Runner shim (typealias over GitHubRunner)

/// Test-only typealias restoring the pre-refactor `Runner` name.
typealias Runner = GitHubRunner

extension GitHubRunner {
    /// Test-only convenience init matching the pre-refactor
    /// `Runner(id:name:status:busy:metrics:)` signature.
    ///
    /// `GitHubRunner.labels` is `[GitHubRunnerLabel]` (not `[String]`) and
    /// the struct has no public memberwise init, so we round-trip through JSON.
    /// The `metrics` parameter is intentionally ignored — use
    /// `displayStatus(metrics:)` at the call site instead.
    init(id: Int, name: String, status: RunnerStatus, busy: Bool = false, metrics: RunnerMetrics? = nil) {
        let json = "{\"id\":\(id),\"name\":\"\(name)\",\"status\":\"\(status.rawValue)\",\"busy\":\(busy ? "true" : "false"),\"labels\":[]}"
        self = try! JSONDecoder().decode(GitHubRunner.self, from: Data(json.utf8))
    }

    /// Convenience forwarder for tests that call `runner.displayStatus` without args.
    var displayStatus: String {
        let fn: (RunnerMetrics?) -> String = self.displayStatus(metrics:)
        return fn(nil)
    }
}

// MARK: - Private ISO8601 formatter for test shim

nonisolated(unsafe) private let _testISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
