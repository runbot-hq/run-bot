// MainHierarchyStateTests.swift
// RunBotTests

import Testing
@testable import RunBotCore
@testable import RunBot

/// Four behavioral contracts for ``MainHierarchyState``:
///   expansionCleanupContract   - per-group keying, full<->partial<->collapsed job cleanup
///   firstObservationContract   - automatic expansion policy on first status observation
///   statusTransitionContract   - reconcile transitions: collapse, expand, user-intent preservation
///   retainGroupsPrunesState    - stale expansion, job, and status removal
@MainActor
struct MainHierarchyStateTests {

    // MARK: - 1. Expansion / job-state lifecycle

    @Test
    func expansionCleanupContract() {
        let state = MainHierarchyState()

        // No entry for unseen group.
        #expect(state.expansion(for: "wf-a") == nil)

        // Full expansion + jobs on two independent groups.
        state.setExpansion(.full, for: "wf-a")
        state.setJobs([1, 2], for: "wf-a")
        state.setJobs([3], for: "wf-b")

        #expect(state.expansion(for: "wf-a") == .full)
        #expect(state.jobs(for: "wf-a") == [1, 2])
        #expect(state.jobs(for: "wf-b") == [3])

        // Full -> partial clears nested jobs for wf-a, leaves wf-b intact.
        state.setExpansion(.partial, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .partial)
        #expect(state.jobs(for: "wf-a").isEmpty)
        #expect(state.jobs(for: "wf-b") == [3])

        // Re-populate wf-a then collapse -- clears jobs again.
        state.setExpansion(.full, for: "wf-a")
        state.setJobs([4], for: "wf-a")
        state.setExpansion(.collapsed, for: "wf-a")

        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // MARK: - 2. First-observation policy

    @Test
    func firstObservationContract() {
        let cases: [(status: RBStatus, expected: MainHierarchyState.WorkflowExpansion)] = [
            (.inProgress, .partial),
            (.queued,     .collapsed),
            (.success,    .collapsed),
            (.failed,     .collapsed)
        ]

        for (index, testCase) in cases.enumerated() {
            let state   = MainHierarchyState()
            let groupID = "wf-\(index)"

            let changed = state.reconcile(status: testCase.status, for: groupID)

            #expect(changed)
            #expect(state.expansion(for: groupID) == testCase.expected)
            #expect(state.status(for: groupID) == testCase.status)
        }
    }

    // MARK: - 3. Status transition contract

    @Test
    func statusTransitionContract() {
        typealias E = MainHierarchyState.WorkflowExpansion

        // Parallel typed arrays avoid Swift tuple-inference degradation on 5+ element tuples.
        let initialStatuses:    [RBStatus] = [.inProgress, .inProgress, .queued,  .success, .failed]
        let initialExpansions:  [E]        = [.partial,    .partial,    .collapsed, .full,   .full]
        let newStatuses:        [RBStatus] = [.success,    .failed,     .inProgress, .success, .success]
        let expectedExpansions: [E]        = [.collapsed,  .collapsed,  .partial,  .full,    .full]
        let expectedChanges:    [Bool]     = [true,        true,        true,      false,    false]
        let shouldClearJobs:    [Bool]     = [true,        true,        false,     false,    false]

        for i in initialStatuses.indices {
            let state   = MainHierarchyState()
            let groupID = "wf-\(i)"

            state.reconcile(status: initialStatuses[i], for: groupID)
            state.setExpansion(initialExpansions[i], for: groupID)
            state.setJobs([1, 2], for: groupID)

            let changed = state.reconcile(status: newStatuses[i], for: groupID)

            #expect(state.expansion(for: groupID) == expectedExpansions[i])
            #expect(changed == expectedChanges[i])
            #expect(state.status(for: groupID) == newStatuses[i])

            if shouldClearJobs[i] {
                #expect(state.jobs(for: groupID).isEmpty)
            } else {
                #expect(state.jobs(for: groupID) == [1, 2])
            }
        }
    }

    // MARK: - 4. Pruning contract

    @Test
    func retainGroupsPrunesState() {
        let state = MainHierarchyState()

        state.setExpansion(.full,    for: "keep")
        state.setJobs([1],           for: "keep")
        state.setStatus(.success,    for: "keep")

        state.setExpansion(.partial, for: "stale")
        state.setJobs([2],           for: "stale")
        state.setStatus(.inProgress, for: "stale")

        state.retainGroups(["keep"])

        #expect(state.expansion(for: "keep") == .full)
        #expect(state.jobs(for: "keep")      == [1])
        #expect(state.status(for: "keep")    == .success)

        #expect(state.expansion(for: "stale") == nil)
        #expect(state.jobs(for: "stale").isEmpty)
        #expect(state.status(for: "stale")    == nil)
    }
}
