// GitHubTimestampParsingTests.swift
// RunBotCoreTests
//
// Regression tests for GitHub timestamp parsing.
//
// GitHub returns both "2026-08-08T16:07:14Z" (no fractional seconds) and
// "2026-08-08T16:07:14.000Z" (with fractional seconds) depending on endpoint.
// Both must parse correctly and produce accurate time-interval output.
import Foundation
import Testing
import GitHubClient
@testable import RunBotCore

// MARK: - JSON helper (GitHubStep has no public memberwise init)

/// Decodes a `GitHubStep` from a minimal JSON object with the given raw timestamps.
private func makeStep(
    startedAt: String?,
    completedAt: String?,
    conclusion: String? = "success"
) throws -> GitHubStep {
    let startJSON      = startedAt.map   { "\"\($0)\"" } ?? "null"
    let endJSON        = completedAt.map { "\"\($0)\"" } ?? "null"
    let conclusionJSON = conclusion.map  { "\"\($0)\"" } ?? "null"
    let json = """
    {"number":1,"name":"S","status":"completed",
     "conclusion":\(conclusionJSON),
     "started_at":\(startJSON),
     "completed_at":\(endJSON)}
    """
    return try JSONDecoder().decode(GitHubStep.self, from: Data(json.utf8))
}

/// Decodes a `GitHubJob` from a minimal JSON object with the given raw timestamps.
private func decodeJob(
    startedAt: String,
    completedAt: String
) throws -> GitHubJob {
    let json = """
    {"id":100,"run_id":200,"name":"build","status":"completed",
     "conclusion":"success",
     "started_at":\"\(startedAt)\",
     "completed_at":\"\(completedAt)\"}
    """
    return try JSONDecoder().decode(GitHubJob.self, from: Data(json.utf8))
}

// MARK: - Tests

@Suite("GitHub timestamp integration")
struct GitHubTimestampParsingTests {

    /// Standard and fractional GitHub timestamps must parse on both Job and Step,
    /// and the decoded interval must match the expected duration within 1 ms.
    @Test
    func jobAndStepParseSupportedTimestampFormats() throws {
        let cases: [
            (
                label: String,
                start: String,
                end: String,
                expectedDuration: TimeInterval
            )
        ] = [
            (
                "standard",
                "2026-08-08T16:07:14Z",
                "2026-08-08T16:07:15Z",
                1
            ),
            (
                "fractional",
                "2026-08-08T16:07:14.123Z",
                "2026-08-08T16:07:15.456Z",
                1.333
            )
        ]

        for testCase in cases {
            // Job
            let job = GitHubJob(
                id: 1,
                runID: 1,
                name: "job",
                status: "completed",
                conclusion: "success",
                startedAt: testCase.start,
                completedAt: testCase.end
            )

            let jobStart = try #require(
                job.startDate,
                "\(testCase.label): job start"
            )
            let jobEnd = try #require(
                job.completedDate,
                "\(testCase.label): job end"
            )

            #expect(
                abs(jobEnd.timeIntervalSince(jobStart) - testCase.expectedDuration) < 0.001,
                "\(testCase.label): job interval"
            )

            // Step (JSON round-trip — no public memberwise init)
            let step = try makeStep(
                startedAt: testCase.start,
                completedAt: testCase.end
            )

            let stepStart = try #require(
                step.startDate,
                "\(testCase.label): step start"
            )
            let stepEnd = try #require(
                step.completedDate,
                "\(testCase.label): step end"
            )

            #expect(
                abs(stepEnd.timeIntervalSince(stepStart) - testCase.expectedDuration) < 0.001,
                "\(testCase.label): step interval"
            )
        }
    }

    /// completedDuration derived fallback: when stored aggregate timestamps are nil,
    /// per-job timestamps must provide the duration.
    ///
    /// Integration path:
    ///   standard GitHub timestamp -> JSON decoding -> job date parsing
    ///   -> aggregate timestamps absent -> duration derived from jobs
    @Test
    func completedDurationDerivesFromDecodedJobTimestamps() throws {
        let rawJob = try decodeJob(
            startedAt: "2026-08-08T16:03:42Z",
            completedAt: "2026-08-08T16:08:14Z"
        )

        let job = ActiveJob(
            raw: rawJob,
            isDimmed: false,
            scope: "owner/repo"
        )
        let group = WorkflowActionGroup.makeTestGroup(
            status: .completed,
            conclusion: .success,
            jobs: [job],
            firstJobStartedAt: nil,
            lastJobCompletedAt: nil
        )

        let duration = try #require(
            group.completedDuration,
            "Fallback must produce non-nil duration"
        )
        #expect(
            abs(duration - 272) < 0.001,
            "Expected ~272s from derived fallback, got \(duration)"
        )
    }
}
