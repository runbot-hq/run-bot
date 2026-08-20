// WorkflowActionGroupProgressTests.swift
// RunBotCoreTests
//
// Regression guard for issue #2630: `jobProgress` must count only `.success`
// conclusions in the numerator; failures, cancellations, and in-progress jobs
// must not increment the succeeded count.
import Testing
@testable import RunBotCore

@Suite("WorkflowActionGroup.jobProgress")
struct WorkflowActionGroupProgressTests {

    /// Regression: one success, one failure, one in-progress → "1/3" (#2630).
    @Test func progressCountsOnlySuccesses() {
        let group = WorkflowActionGroup.makeTestGroup(
            jobs: [
                makeJob(id: 1, conclusion: .success),
                makeJob(id: 2, conclusion: .failure),
                makeJob(id: 3, conclusion: nil, status: .inProgress),
            ]
        )
        #expect(group.jobsSucceeded == 1)
        #expect(group.jobsTotal == 3)
        #expect(group.jobProgress == "1/3")
    }

    // MARK: - Helpers

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
