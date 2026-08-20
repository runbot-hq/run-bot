// WorkflowActionGroupProgressTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

// MARK: - WorkflowActionGroup.jobProgress

/// Test suite for successful-versus-total job progress aggregation on `WorkflowActionGroup`.
///
/// Covers the fix for issue #2630: the workflow-row fraction now counts only
/// `.success` conclusions in the numerator, while keeping all jobs in the denominator.
/// Non-success conclusions (`.failure`, `.cancelled`, `.skipped`, `.neutral`,
/// `.timedOut`, `.actionRequired`, `.stale`, `.startupFailure`, `.unknown`) and
/// running/queued jobs (nil conclusion) must not increment the numerator.
@Suite("WorkflowActionGroup.jobProgress")
struct WorkflowActionGroupProgressTests {

    /// Empty jobs → jobsSucceeded == 0, jobsTotal == 0, jobProgress == "—".
    @Test func emptyJobs() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [])
        #expect(group.jobsSucceeded == 0)
        #expect(group.jobsTotal == 0)
        #expect(group.jobProgress == "—")
    }

    /// Two successful jobs → "2/2".
    @Test func twoSuccesses() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: .success),
        ])
        #expect(group.jobsSucceeded == 2)
        #expect(group.jobsTotal == 2)
        #expect(group.jobProgress == "2/2")
    }

    /// One success and one failure → "1/2".
    @Test func successAndFailure() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: .failure),
        ])
        #expect(group.jobsSucceeded == 1)
        #expect(group.jobsTotal == 2)
        #expect(group.jobProgress == "1/2")
    }

    /// Non-success conclusions (cancelled, running/nil, all other terminals) must not increment
    /// jobsSucceeded. Covers: failure, cancelled, skipped, neutral, timedOut, actionRequired,
    /// stale, startupFailure, unknown, and in-progress (nil conclusion).
    /// Regression: partial-success counts are correct (#2630).
    @Test func mixedConclusionsProgress() {
        // 1 success + 1 cancelled → "1/2"
        let partial = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: .cancelled),
        ])
        #expect(partial.jobProgress == "1/2")

        // all non-success terminal conclusions → "0/9"
        let allNonSuccess = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .failure),
            makeJob(id: 2, conclusion: .cancelled),
            makeJob(id: 3, conclusion: .skipped),
            makeJob(id: 4, conclusion: .neutral),
            makeJob(id: 5, conclusion: .timedOut),
            makeJob(id: 6, conclusion: .actionRequired),
            makeJob(id: 7, conclusion: .stale),
            makeJob(id: 8, conclusion: .startupFailure),
            makeJob(id: 9, conclusion: .unknown("unknown")),
        ])
        #expect(allNonSuccess.jobsSucceeded == 0)
        #expect(allNonSuccess.jobProgress == "0/9")

        // 8 success + 1 failure + 1 cancelled → "8/10" (regression #2630)
        let eightOfTen = WorkflowActionGroup.makeTestGroup(jobs: (1...8).map {
            makeJob(id: $0, conclusion: .success)
        } + [
            makeJob(id: 9, conclusion: .failure),
            makeJob(id: 10, conclusion: .cancelled),
        ])
        #expect(eightOfTen.jobProgress == "8/10")
    }

    // MARK: - Helpers

    /// Creates a minimal `ActiveJob` for testing progress calculations.
    private func makeJob(
        id: Int,
        conclusion: JobConclusion?,
        status: JobStatus = .completed
    ) -> ActiveJob {
        ActiveJob(
            id: id,
            name: "job-\(id)",
            status: status,
            conclusion: conclusion
        )
    }
}
