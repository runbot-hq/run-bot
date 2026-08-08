// GitHubTimestampParsingTests.swift
// RunBotCoreTests
//
// Regression tests for GitHub timestamp parsing.
//
// GitHub returns both "2026-08-08T16:07:14Z" (no fractional seconds) and
// "2026-08-08T16:07:14.000Z" (with fractional seconds) depending on endpoint.
// Both must parse to non-nil Date values and produce correct elapsed/duration output.
import Foundation
import Testing
import GitHubClient
@testable import RunBotCore

// MARK: - GitHubJob timestamp parsing

@Suite("GitHubJob timestamp parsing")
struct GitHubJobTimestampParsingTests {

    /// Standard Z-suffix timestamp (no fractional seconds) must parse to a non-nil Date.
    @Test func parsesStandardGitHubTimestampOnJob() {
        let job = GitHubJob(
            id: 1, runID: 0, name: "J", status: "completed",
            startedAt: "2026-08-08T16:03:42Z",
            completedAt: "2026-08-08T16:08:14Z"
        )
        #expect(job.startDate != nil)
        #expect(job.completedDate != nil)
    }

    /// Fractional-seconds timestamp must continue to parse to a non-nil Date.
    @Test func parsesFractionalGitHubTimestampOnJob() {
        let job = GitHubJob(
            id: 1, runID: 0, name: "J", status: "completed",
            startedAt: "2026-08-08T16:03:42.123Z",
            completedAt: "2026-08-08T16:08:14.456Z"
        )
        #expect(job.startDate != nil)
        #expect(job.completedDate != nil)
    }

    /// Standard-format job: elapsed rounds to correct MM:SS string.
    @Test func jobElapsedWithStandardTimestamps() {
        let job = GitHubJob(
            id: 1, runID: 0, name: "J", status: "completed",
            conclusion: "success",
            startedAt: "2026-08-08T16:07:14Z",
            completedAt: "2026-08-08T16:07:15Z"
        )
        // 1-second completed job → "00:01"
        #expect(job.elapsed == "00:01")
    }
}

// MARK: - GitHubStep timestamp parsing
//
// GitHubStep has no public memberwise init — instances are constructed via JSON
// round-trip (matching the pattern in TestModelHelpers.swift).

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

@Suite("GitHubStep timestamp parsing")
struct GitHubStepTimestampParsingTests {

    /// Standard Z-suffix timestamp (no fractional seconds) must parse to a non-nil Date.
    @Test func parsesStandardGitHubTimestampOnStep() throws {
        let step = try makeStep(
            startedAt: "2026-08-08T16:07:14Z",
            completedAt: "2026-08-08T16:07:15Z"
        )
        #expect(step.startDate != nil)
        #expect(step.completedDate != nil)
    }

    /// Fractional-seconds timestamp must continue to parse to a non-nil Date.
    @Test func parsesFractionalGitHubTimestampOnStep() throws {
        let step = try makeStep(
            startedAt: "2026-08-08T16:07:14.000Z",
            completedAt: "2026-08-08T16:07:15.500Z"
        )
        #expect(step.startDate != nil)
        #expect(step.completedDate != nil)
    }

    /// Regression: step with 1-second standard timestamps must display "00:01".
    ///
    /// Reproduces the screenshot failure: `16:07:14 → 16:07:15 · --:--`
    /// The elapsed string must be "00:01", not "--:--".
    @Test func stepElapsedOneSecondStandardTimestamps() throws {
        let step = try makeStep(
            startedAt: "2026-08-08T16:07:14Z",
            completedAt: "2026-08-08T16:07:15Z"
        )
        #expect(step.elapsed == "00:01")
    }
}

// MARK: - Part 9: Fetcher integration (completedDuration)

@Suite("WorkflowActionGroup.completedDuration — standard timestamps")
struct WorkflowCompletedDurationStandardTimestampTests {

    /// Job JSON with non-fractional timestamps must produce correct group aggregates.
    ///
    /// started_at:   2026-08-08T16:03:42Z
    /// completed_at: 2026-08-08T16:08:14Z  → duration = 272 seconds
    @Test func completedDurationFromStandardTimestamps() throws {
        let json = """
        {"id":100,"run_id":200,"name":"build","status":"completed",
         "conclusion":"success",
         "started_at":"2026-08-08T16:03:42Z",
         "completed_at":"2026-08-08T16:08:14Z"}
        """
        let rawJob = try JSONDecoder().decode(GitHubJob.self, from: Data(json.utf8))
        #expect(rawJob.startDate != nil, "startDate must be non-nil for standard timestamp")
        #expect(rawJob.completedDate != nil, "completedDate must be non-nil for standard timestamp")

        let job = ActiveJob(raw: rawJob, isDimmed: false, scope: "owner/repo")
        let group = WorkflowActionGroup.makeTestGroup(
            status: .completed,
            conclusion: .success,
            jobs: [job],
            firstJobStartedAt: rawJob.startDate,
            lastJobCompletedAt: rawJob.completedDate
        )

        #expect(group.firstJobStartedAt != nil)
        #expect(group.lastJobCompletedAt != nil)
        let duration = try #require(group.completedDuration)
        #expect(abs(duration - 272) < 1, "Expected ~272s, got \(duration)")
    }

    /// completedDuration derived fallback: even when stored aggregates are nil,
    /// per-job timestamps provide the duration.
    @Test func completedDurationDerivedFromJobsWhenAggregatesNil() throws {
        let json = """
        {"id":100,"run_id":200,"name":"build","status":"completed",
         "conclusion":"success",
         "started_at":"2026-08-08T16:03:42Z",
         "completed_at":"2026-08-08T16:08:14Z"}
        """
        let rawJob = try JSONDecoder().decode(GitHubJob.self, from: Data(json.utf8))
        let job = ActiveJob(raw: rawJob, isDimmed: false, scope: "owner/repo")
        // Pass nil aggregates to prove the fallback path works.
        let group = WorkflowActionGroup.makeTestGroup(
            status: .completed,
            conclusion: .success,
            jobs: [job],
            firstJobStartedAt: nil,
            lastJobCompletedAt: nil
        )

        let duration = try #require(group.completedDuration, "Fallback must produce non-nil duration")
        #expect(abs(duration - 272) < 1, "Expected ~272s from derived fallback, got \(duration)")
    }
}
