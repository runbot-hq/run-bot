// WorkflowSelectionTests.swift
// RunBotCore

import Testing
@testable import RunBotCore

/// Smoke test — just enough to confirm WorkflowSelection exists and basic
/// select/clear round-trips work. Detailed reconcile behaviour is intentionally
/// not locked down here until the API is stable.
@MainActor
struct WorkflowSelectionTests {

    @Test func selectAndClearWorkflow() {
        let sel = WorkflowSelection()
        sel.selectWorkflow("sha-1")
        #expect(sel.workflowID == "sha-1")
        sel.selectWorkflow(nil)
        #expect(sel.workflowID == nil)
    }

    @Test func selectJobInWorkflowSetsFullPath() {
        let sel = WorkflowSelection()
        sel.selectJob(7, inWorkflow: "sha-1")
        #expect(sel.workflowID == "sha-1")
        #expect(sel.jobID == 7)
        #expect(sel.stepNumber == nil)
    }

    @Test func selectDifferentJobClearsStep() {
        let sel = WorkflowSelection()
        sel.selectStep(2, ofJob: 7, inWorkflow: "sha-1")
        #expect(sel.stepNumber == 2)
        // Re-selecting the same job keeps the step (collapse tap).
        sel.selectJob(7, inWorkflow: "sha-1")
        #expect(sel.stepNumber == 2)
        // Selecting a different job clears the stale step.
        sel.selectJob(8, inWorkflow: "sha-1")
        #expect(sel.stepNumber == nil)
    }

    @Test func selectStepSetsFullPathAcrossWorkflows() {
        let sel = WorkflowSelection()
        sel.selectWorkflow("sha-1")
        sel.selectStep(3, ofJob: 9, inWorkflow: "sha-2")
        #expect(sel.workflowID == "sha-2")
        #expect(sel.jobID == 9)
        #expect(sel.stepNumber == 3)
    }
}
