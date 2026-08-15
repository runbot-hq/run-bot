// MigrationJobRowFormattingTests.swift
// RunBotTests

import Testing
@testable import RunBot
@testable import RunBotCore
import GitHubClient

struct MigrationJobRowFormattingTests {

    @Test func stepProgressIsNilWhenEmpty() {
        let job = ActiveJob(raw: GitHubJob.fixture(id: 1, steps: []))
        let done = job.steps.filter { $0.conclusion != nil }.count
        #expect(job.steps.isEmpty)
        #expect(done == 0)
    }

    @Test func stepProgressCountsDoneSteps() {
        let s1 = GitHubStep(number: 1, name: "A", status: "completed", conclusion: "success")
        let s2 = GitHubStep(number: 2, name: "B", status: "in_progress")
        let job = ActiveJob(raw: GitHubJob.fixture(id: 1, steps: [s1, s2]))
        let done = job.steps.filter { $0.conclusion != nil }.count
        #expect(done == 1)
        #expect(job.steps.count == 2)
    }
}
