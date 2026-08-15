// MigrationWorkflowSelectionTests.swift
// RunBotTests

import Testing
@testable import RunBot
@testable import RunBotCore
import GitHubClient

// MARK: - Fixtures

private let stepA = GitHubStep(number: 1, name: "Checkout", status: "completed", conclusion: "success",
                               startedAt: "2024-01-01T00:00:00Z", completedAt: "2024-01-01T00:01:00Z")
private let stepB = GitHubStep(number: 2, name: "Build",    status: "in_progress",
                               startedAt: "2024-01-01T00:01:00Z")

private func makeJob(id: Int, steps: [GitHubStep] = []) -> ActiveJob {
    ActiveJob(raw: GitHubJob.fixture(id: id, steps: steps))
}

private func makeWorkflow(sha: String, jobs: [ActiveJob] = []) -> WorkflowActionGroup {
    WorkflowActionGroup.fixture(headSha: sha, jobs: jobs)
}

// MARK: - Selection tests

@MainActor
struct MigrationWorkflowSelectionTests {

    @Test func selectWorkflowClearsJobAndStep() {
        let sel = MigrationWorkflowSelection()
        sel.selectJob(99)
        sel.selectStep(2)
        sel.selectWorkflow("sha-1")
        #expect(sel.workflowID == "sha-1")
        #expect(sel.jobID == nil)
        #expect(sel.stepNumber == nil)
    }

    @Test func selectJobClearsStep() {
        let sel = MigrationWorkflowSelection()
        sel.selectStep(3)
        sel.selectJob(42)
        #expect(sel.jobID == 42)
        #expect(sel.stepNumber == nil)
    }

    @Test func clearWorkflowClearsChain() {
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("sha-x")
        sel.selectJob(10)
        sel.selectStep(1)
        sel.selectWorkflow(nil)
        #expect(sel.workflowID == nil)
        #expect(sel.jobID == nil)
        #expect(sel.stepNumber == nil)
    }

    @Test func reconcileRemovesMissingWorkflow() {
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("gone")
        sel.selectJob(1)
        sel.selectStep(1)
        sel.reconcile(workflows: [])
        #expect(sel.workflowID == nil)
        #expect(sel.jobID == nil)
        #expect(sel.stepNumber == nil)
    }

    @Test func reconcileRemovesMissingJob() {
        let job = makeJob(id: 5, steps: [stepA])
        let wf  = makeWorkflow(sha: "sha-1", jobs: [job])
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("sha-1")
        sel.selectJob(999)          // does not exist
        sel.selectStep(1)
        sel.reconcile(workflows: [wf])
        #expect(sel.workflowID == "sha-1")
        #expect(sel.jobID == nil)
        #expect(sel.stepNumber == nil)
    }

    @Test func reconcileRemovesMissingStep() {
        let job = makeJob(id: 5, steps: [stepA])
        let wf  = makeWorkflow(sha: "sha-1", jobs: [job])
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("sha-1")
        sel.selectJob(5)
        sel.selectStep(99)          // does not exist
        sel.reconcile(workflows: [wf])
        #expect(sel.workflowID == "sha-1")
        #expect(sel.jobID == 5)
        #expect(sel.stepNumber == nil)
    }

    @Test func reconcileKeepsValidChain() {
        let job = makeJob(id: 5, steps: [stepA, stepB])
        let wf  = makeWorkflow(sha: "sha-1", jobs: [job])
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("sha-1")
        sel.selectJob(5)
        sel.selectStep(1)
        sel.reconcile(workflows: [wf])
        #expect(sel.workflowID == "sha-1")
        #expect(sel.jobID == 5)
        #expect(sel.stepNumber == 1)
    }
}
