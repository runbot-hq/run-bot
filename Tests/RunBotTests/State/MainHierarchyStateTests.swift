// MainHierarchyStateTests.swift
// RunBotTests

import Testing
@testable import RunBot

@MainActor
struct MainHierarchyStateTests {

    // 1. New group has no stored entry
    @Test func newGroupHasNoEntry() {
        let state = MainHierarchyState()
        #expect(state.expansion(for: "group-1") == nil)
    }

    // 2. Explicit .collapsed is distinct from no entry
    @Test func collapsedIsDistinctFromAbsent() {
        let state = MainHierarchyState()
        state.setExpansion(.collapsed, for: "group-1")
        #expect(state.expansion(for: "group-1") == .collapsed)
        #expect(state.expansion(for: "group-2") == nil)
    }

    // 3. .partial survives repeated reads
    @Test func partialSurvivesRepeatedReads() {
        let state = MainHierarchyState()
        state.setExpansion(.partial, for: "g")
        #expect(state.expansion(for: "g") == .partial)
        #expect(state.expansion(for: "g") == .partial)
    }

    // 4. .full survives repeated reads
    @Test func fullSurvivesRepeatedReads() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "g")
        #expect(state.expansion(for: "g") == .full)
        #expect(state.expansion(for: "g") == .full)
    }

    // 5. Job IDs stored per workflow group
    @Test func jobIDsStoredPerGroup() {
        let state = MainHierarchyState()
        state.setJobs([1, 2, 3], for: "wf-a")
        #expect(state.jobs(for: "wf-a") == [1, 2, 3])
    }

    // 6. Two groups do not share nested job state
    @Test func groupsDoNotShareJobState() {
        let state = MainHierarchyState()
        state.setJobs([1], for: "wf-a")
        state.setJobs([2], for: "wf-b")
        #expect(state.jobs(for: "wf-a") == [1])
        #expect(state.jobs(for: "wf-b") == [2])
    }

    // 7. Empty job sets remove their dictionary entry (returns empty set)
    @Test func emptyJobSetIsEmpty() {
        let state = MainHierarchyState()
        state.setJobs([1], for: "wf-a")
        state.setJobs([], for: "wf-a")
        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // 8. retainGroups keeps current groups
    @Test func retainGroupsKeepsCurrent() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.retainGroups(["wf-a"])
        #expect(state.expansion(for: "wf-a") == .full)
    }

    // 9. retainGroups removes obsolete workflow expansion
    @Test func retainGroupsRemovesObsoleteExpansion() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-stale")
        state.retainGroups([])
        #expect(state.expansion(for: "wf-stale") == nil)
    }

    // 10. retainGroups removes obsolete nested job state
    @Test func retainGroupsRemovesObsoleteJobs() {
        let state = MainHierarchyState()
        state.setJobs([1, 2], for: "wf-stale")
        state.retainGroups([])
        #expect(state.jobs(for: "wf-stale").isEmpty)
    }

    // 11. Reordering same group IDs does not affect stored state
    @Test func reorderingDoesNotAffectState() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.setExpansion(.partial, for: "wf-b")
        state.retainGroups(["wf-b", "wf-a"])
        #expect(state.expansion(for: "wf-a") == .full)
        #expect(state.expansion(for: "wf-b") == .partial)
    }

    // 12. Transitioning full -> partial clears nested jobs
    @Test func fullToPartialClearsJobs() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.setJobs([1, 2], for: "wf-a")
        let oldExpansion = state.expansion(for: "wf-a")
        let newExpansion = MainHierarchyState.WorkflowExpansion(false) // .partial
        state.setExpansion(newExpansion, for: "wf-a")
        if case (.some(.full), .partial) = (oldExpansion, newExpansion) {
            state.clearJobs(for: "wf-a")
        }
        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // 13. Explicit collapse clears nested jobs
    @Test func explicitCollapseClearsJobs() {
        let state = MainHierarchyState()
        state.setJobs([1, 2], for: "wf-a")
        state.setExpansion(.collapsed, for: "wf-a")
        state.clearJobs(for: "wf-a")
        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // 14. visibleCount defaults to 10
    @Test func visibleCountDefaults() {
        let state = MainHierarchyState()
        #expect(state.visibleCount == 10)
    }

    // 15. visibleCount survives mutation
    @Test func visibleCountSurvivesMutation() {
        let state = MainHierarchyState()
        state.visibleCount = 25
        #expect(state.visibleCount == 25)
    }
}
