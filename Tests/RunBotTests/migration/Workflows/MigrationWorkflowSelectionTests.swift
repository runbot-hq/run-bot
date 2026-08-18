// MigrationWorkflowSelectionTests.swift
// RunBotTests

import Testing
@testable import RunBot

/// Smoke test — just enough to confirm MigrationWorkflowSelection exists and basic
/// select/clear round-trips work. Detailed reconcile behaviour is intentionally
/// not locked down here until the API is stable.
@MainActor
struct MigrationWorkflowSelectionTests {

    @Test func selectAndClearWorkflow() {
        let sel = MigrationWorkflowSelection()
        sel.selectWorkflow("sha-1")
        #expect(sel.workflowID == "sha-1")
        sel.selectWorkflow(nil)
        #expect(sel.workflowID == nil)
    }
}
