// MigrationWorkflowRowFormattingTests.swift
// RunBotTests

import Testing
@testable import RunBot
@testable import RunBotCore

struct MigrationWorkflowRowFormattingTests {

    @Test func jobProgressIsEmptyWhenNoJobs() {
        let wf = WorkflowActionGroup.fixture(headSha: "sha-1", jobs: [])
        #expect(wf.jobs.isEmpty)
        #expect(wf.jobProgress == "—")
    }

    @Test func jobProgressShowsSucceededOverTotal() {
        let jobA = ActiveJob(raw: GitHubJob.fixture(id: 1, conclusion: "success"))
        let jobB = ActiveJob(raw: GitHubJob.fixture(id: 2, conclusion: nil))
        let wf = WorkflowActionGroup.fixture(headSha: "sha-1", jobs: [jobA, jobB])
        #expect(wf.jobProgress == "1/2")
    }
}
