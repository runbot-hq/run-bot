// WorkflowActionGroupProgressTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

// MARK: - WorkflowActionGroup.jobProgress

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

    /// One success and one cancelled job → "1/2".
    @Test func successAndCancelled() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: .cancelled),
        ])
        #expect(group.jobsSucceeded == 1)
        #expect(group.jobsTotal == 2)
        #expect(group.jobProgress == "1/2")
    }

    /// One success and one running/queued job with nil conclusion → "1/2".
    @Test func successAndRunningJob() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: nil, status: .inProgress),
        ])
        #expect(group.jobsSucceeded == 1)
        #expect(group.jobsTotal == 2)
        #expect(group.jobProgress == "1/2")
    }

    /// Non-success conclusions must not increment jobsSucceeded.
    @Test func nonSuccessConclusionsDoNotCount() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
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
        #expect(group.jobsSucceeded == 0)
        #expect(group.jobsTotal == 9)
        #expect(group.jobProgress == "0/9")
    }

    /// Regression: 8 .success + 1 .failure + 1 other non-success → "8/10".
    @Test func eightOutOfTen() {
        let group = WorkflowActionGroup.makeTestGroup(jobs: [
            makeJob(id: 1, conclusion: .success),
            makeJob(id: 2, conclusion: .success),
            makeJob(id: 3, conclusion: .success),
            makeJob(id: 4, conclusion: .success),
            makeJob(id: 5, conclusion: .success),
            makeJob(id: 6, conclusion: .success),
            makeJob(id: 7, conclusion: .success),
            makeJob(id: 8, conclusion: .success),
            makeJob(id: 9, conclusion: .failure),
            makeJob(id: 10, conclusion: .cancelled),
        ])
        #expect(group.jobsSucceeded == 8)
        #expect(group.jobsTotal == 10)
        #expect(group.jobProgress == "8/10")
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
