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

        struct TransitionCase {
            let initialStatus: RBStatus
            let initialExpansion: E
            let newStatus: RBStatus
            let expectedExpansion: E
            let expectedChanged: Bool
            let shouldClearJobs: Bool
        }

        let transitions: [TransitionCase] = [
            // Terminal status on a partial expansion collapses and clears jobs.
            .init(initialStatus: .inProgress, initialExpansion: .partial, newStatus: .success,
                  expectedExpansion: .collapsed, expectedChanged: true, shouldClearJobs: true),
            .init(initialStatus: .inProgress, initialExpansion: .partial, newStatus: .failed,
                  expectedExpansion: .collapsed, expectedChanged: true, shouldClearJobs: true),
            // Work resuming from queued expands collapsed -> partial, jobs untouched.
            .init(initialStatus: .queued, initialExpansion: .collapsed, newStatus: .inProgress,
                  expectedExpansion: .partial, expectedChanged: true, shouldClearJobs: false),
            // Same-status reconciles leave full expansions and jobs intact.
            .init(initialStatus: .success, initialExpansion: .full, newStatus: .success,
                  expectedExpansion: .full, expectedChanged: false, shouldClearJobs: false),
            .init(initialStatus: .failed, initialExpansion: .full, newStatus: .success,
                  expectedExpansion: .full, expectedChanged: false, shouldClearJobs: false)
        ]

        for (index, transition) in transitions.enumerated() {
            let state   = MainHierarchyState()
            let groupID = "wf-\(index)"

            state.reconcile(status: transition.initialStatus, for: groupID)
            state.setExpansion(transition.initialExpansion, for: groupID)
            state.setJobs([1, 2], for: groupID)

            let changed = state.reconcile(status: transition.newStatus, for: groupID)

            #expect(state.expansion(for: groupID) == transition.expectedExpansion)
            #expect(changed == transition.expectedChanged)
            #expect(state.status(for: groupID) == transition.newStatus)

            if transition.shouldClearJobs {
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
