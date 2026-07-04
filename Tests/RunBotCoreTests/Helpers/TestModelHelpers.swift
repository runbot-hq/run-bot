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
    /// Test-only convenience init matching the pre-refactor ActiveJob memberwise signature.
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

    // Typed-status overload used by ActiveJobRBStatusTests and ActiveJobAsCompletedTests.
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

    /// Test bridge: returns the effective typed status (statusOverride ?? raw.jobStatus).
    var status: JobStatus { jobStatus }
    /// Test bridge: returns the effective typed conclusion.
    var conclusion: JobConclusion? { jobConclusion }
    /// Test bridge: returns the parsed completedAt date.
    var completedAt: Date? { completedDate }
    /// Test bridge: returns the parsed startedAt date.
    var startedAt: Date? { startDate }
    /// Test bridge: returns the parsed createdAt date.
    var createdAt: Date? { createdDate }
}

// MARK: - JobStep shim (typealias + convenience init)

/// Test-only typealias restoring the pre-refactor JobStep name.
typealias JobStep = GitHubStep

extension GitHubStep {
    /// Test-only convenience init matching the pre-refactor JobStep init.
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

    // Typed-status overload.
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

// MARK: - GitHubStep full memberwise init (not Decodable-only)

extension GitHubStep {
    /// Full memberwise init for tests — GitHubStep only ships an init(from:Decoder).
    init(
        name: String,
        status: String,
        conclusion: String? = nil,
        number: Int,
        startedAt: String? = nil,
        completedAt: String? = nil
    ) {
        // Encode via JSON round-trip to satisfy the Decodable-only struct.
        let dict: [String: Any?] = [
            "name": name, "status": status, "conclusion": conclusion,
            "number": number, "started_at": startedAt, "completed_at": completedAt
        ]
        let cleaned = dict.compactMapValues { $0 }
        let data = try! JSONSerialization.data(withJSONObject: cleaned)
        self = try! JSONDecoder().decode(GitHubStep.self, from: data)
    }
}

// MARK: - Runner shim (typealias over GitHubRunner)

/// Test-only typealias restoring the pre-refactor Runner name.
typealias Runner = GitHubRunner

extension GitHubRunner {
    /// Test-only convenience init matching the pre-refactor Runner(id:name:status:busy:metrics:).
    init(id: Int, name: String, status: RunnerStatus, busy: Bool = false, metrics: RunnerMetrics? = nil) {
        self.init(id: id, name: name, status: status.rawString, busy: busy, labels: [])
        // metrics is not stored on GitHubRunner — use displayStatus(metrics:) at call site.
    }

    /// Convenience forwarder for tests that call runner.displayStatus without args.
    var displayStatus: String { displayStatus(metrics: nil) }
}

// MARK: - Private ISO8601 formatter for test shim

nonisolated(unsafe) private let _testISO8601: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
