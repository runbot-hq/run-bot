// WorkflowActionGroupRBStatusTests.swift
// RunBotCoreTests
import Testing
@testable import RunBotCore

// MARK: - WorkflowActionGroup.rbStatus

/// Tests for the shared `WorkflowActionGroup.rbStatus` derivation, covering
/// all scenarios described in the #2868 fix.
///
/// The status-bar app (`ActionRowView.rowStatus`) and the windowed migration app
/// (`MigrationWorkflowRow`) both consume this single implementation.
@Suite("WorkflowActionGroup.rbStatus")
struct WorkflowActionGroupRBStatusTests {

    // MARK: - Official completed + success → success

    @Test func completedSuccess() {
        let group = makeGroup(status: .completed, conclusion: .success, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
        ])
        #expect(group.rbStatus == .success)
    }

    // MARK: - Official completed + failure → failed

    @Test func completedFailure() {
        let group = makeGroup(status: .completed, conclusion: .failure, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .failure),
        ])
        #expect(group.rbStatus == .failed)
    }

    @Test func completedTimedOut() {
        let group = makeGroup(status: .completed, conclusion: .timedOut, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .timedOut),
        ])
        #expect(group.rbStatus == .failed)
    }

    @Test func completedStartupFailure() {
        let group = makeGroup(status: .completed, conclusion: .startupFailure, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .startupFailure),
        ])
        #expect(group.rbStatus == .failed)
    }

    @Test func completedActionRequired() {
        let group = makeGroup(status: .completed, conclusion: .actionRequired, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .actionRequired),
        ])
        #expect(group.rbStatus == .failed)
    }

    // MARK: - In-progress, not dimmed → inProgress

    @Test func inProgressNotDimmed() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .inProgress, conclusion: nil),
        ])
        #expect(group.rbStatus == .inProgress)
    }

    // MARK: - In-progress, not dimmed, all known jobs completed → inProgress

    @Test func inProgressNotDimmedAllJobsCompleted() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .success),
        ])
        // Group is not dimmed — run-level snapshot is authoritative.
        #expect(group.rbStatus == .inProgress)
    }

    // MARK: - Dimmed, all jobs completed successfully → success

    @Test func dimmedAllJobsSuccess() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .success),
        ])
        #expect(group.rbStatus == .success)
    }

    // MARK: - Dimmed, successful and skipped jobs → success

    @Test func dimmedSuccessAndSkipped() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .skipped),
        ])
        #expect(group.rbStatus == .success)
    }

    // MARK: - Dimmed, one failed job → failed

    @Test func dimmedOneFailed() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .failure),
        ])
        #expect(group.rbStatus == .failed)
    }

    // MARK: - Dimmed, one cancelled job and no failures → cancelled

    @Test func dimmedCancelledNoFailure() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .cancelled),
        ])
        #expect(group.rbStatus == .cancelled)
    }

    // MARK: - Dimmed, all jobs skipped → skipped

    @Test func dimmedAllSkipped() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .skipped),
            makeJob(id: 2, status: .completed, conclusion: .skipped),
        ])
        #expect(group.rbStatus == .skipped)
    }

    // MARK: - Dimmed, at least one non-terminal job → inProgress

    @Test func dimmedWithNonTerminalJob() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .inProgress, conclusion: nil),
            makeJob(id: 2, status: .completed, conclusion: .success),
        ])
        // Not all jobs are terminal — stays inProgress.
        #expect(group.rbStatus == .inProgress)
    }

    // MARK: - Completed job with nil conclusion — counted by jobsDone

    @Test func completedJobWithNilConclusionCountedByJobsDone() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: nil),
            makeJob(id: 2, status: .completed, conclusion: .success),
        ])
        #expect(group.jobsDone == 2, "jobsDone must count the terminal job even without a conclusion")
        #expect(group.jobsTotal == 2)
        #expect(group.rbStatus == .success)
    }

    // MARK: - Dimmed, all jobs terminal but some conclusions are nil → success

    @Test func dimmedAllTerminalWithNilConclusion() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: nil),
            makeJob(id: 2, status: .completed, conclusion: .success),
            makeJob(id: 3, status: .completed, conclusion: .success),
        ])
        // nil conclusions are filtered out by compactMap; remaining are all success.
        #expect(group.rbStatus == .success)
    }

    // MARK: - allJobsAreTerminal

    @Test func allJobsAreTerminalTrue() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .completed, conclusion: .failure),
        ])
        #expect(group.allJobsAreTerminal == true)
    }

    @Test func allJobsAreTerminalFalseWhenInProgress() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .inProgress, conclusion: nil),
        ])
        #expect(group.allJobsAreTerminal == false)
    }

    @Test func allJobsAreTerminalFalseForEmptyJobs() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [])
        #expect(group.allJobsAreTerminal == false)
    }

    @Test func allJobsAreTerminalFalseForUnknownStatus() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .unknown("new_status"), conclusion: nil),
        ])
        #expect(group.allJobsAreTerminal == false)
    }

    @Test func allJobsAreTerminalFalseForQueuedStatus() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .queued, conclusion: nil),
        ])
        #expect(group.allJobsAreTerminal == false)
    }

    // MARK: - Dimmed, all jobs completed with nil conclusions → success

    @Test func dimmedAllCompletedWithNilConclusions() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: true, jobs: [
            makeJob(id: 1, status: .completed, conclusion: nil),
            makeJob(id: 2, status: .completed, conclusion: nil),
        ])
        #expect(group.allJobsAreTerminal == true)
        #expect(group.rbStatus == .success)
    }

    // MARK: - jobsDone edge cases

    @Test func jobsDoneCountsCompletedJobsWithoutConclusions() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: nil),
            makeJob(id: 2, status: .completed, conclusion: .success),
            makeJob(id: 3, status: .inProgress, conclusion: nil),
        ])
        #expect(group.jobsDone == 2)
        #expect(group.jobsTotal == 3)
    }

    @Test func jobsDoneDoesNotCountUnknownStatus() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .unknown("new_status"), conclusion: nil),
        ])
        #expect(group.jobsDone == 1)
    }

    @Test func jobsDoneDoesNotCountQueuedStatus() {
        let group = makeGroup(status: .inProgress, conclusion: nil, isDimmed: false, jobs: [
            makeJob(id: 1, status: .completed, conclusion: .success),
            makeJob(id: 2, status: .queued, conclusion: nil),
        ])
        #expect(group.jobsDone == 1)
    }

    // MARK: - Helpers

    /// Creates a minimal `WorkflowActionGroup` for testing `rbStatus`.
    private func makeGroup(
        status: JobStatus,
        conclusion: JobConclusion?,
        isDimmed: Bool,
        jobs: [ActiveJob]
    ) -> WorkflowActionGroup {
        let run = WorkflowRunRef(
            id: 1,
            name: "CI",
            status: status,
            conclusion: conclusion,
            htmlUrl: nil
        )
        return WorkflowActionGroup(
            headSha: "aabbccdd",
            label: "aabbccd",
            title: "CI",
            headBranch: "main",
            repo: "owner/repo",
            runs: [run],
            jobs: jobs,
            firstJobStartedAt: nil,
            lastJobCompletedAt: nil,
            createdAt: nil,
            normalizedEvent: "commit",
            isDimmed: isDimmed
        )
    }

    /// Creates a minimal `ActiveJob` for testing.
    private func makeJob(
        id: Int,
        status: JobStatus,
        conclusion: JobConclusion?
    ) -> ActiveJob {
        ActiveJob(
            id: id,
            name: "job-\(id)",
            status: status,
            conclusion: conclusion
        )
    }
}
