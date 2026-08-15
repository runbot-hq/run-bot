// MigrationStepRowFormattingTests.swift
// RunBotTests

import Testing
@testable import RunBotCore
import GitHubClient

struct MigrationStepRowFormattingTests {

    @Test func elapsedOmittedWhenNotStarted() {
        let step = GitHubStep(number: 1, name: "Queued", status: "queued")
        #expect(step.startDate == nil)
    }

    @Test func elapsedPresentWhenStarted() {
        let step = GitHubStep(
            number: 1, name: "Build", status: "completed", conclusion: "success",
            startedAt: "2024-01-01T00:00:00Z", completedAt: "2024-01-01T00:02:30Z"
        )
        #expect(step.startDate != nil)
        let e = step.elapsed(now: step.completedDate ?? Date())
        #expect(!e.isEmpty)
    }

    @Test func elapsedOmittedWhenStartedAtMissing() {
        let step = GitHubStep(number: 2, name: "Waiting", status: "in_progress")
        #expect(step.startDate == nil)
    }
}
