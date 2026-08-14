// MainHierarchyStateTests.swift
// RunBotTests

import Testing
@testable import RunBot

/// Tests for ``MainHierarchyState``.
///
/// Covers expansion storage, job-state cleanup invariants owned by
/// `setExpansion`, status reconciliation (both first-observation and
/// transition), pruning, and visible-count persistence.
@MainActor
struct MainHierarchyStateTests {

    // MARK: - Expansion storage

    /// Verifies that a new workflow group has no stored expansion entry.
    @Test
    func newGroupHasNoEntry() {
        let state = MainHierarchyState()
        #expect(state.expansion(for: "group-1") == nil)
    }

    /// Verifies that an explicit `.collapsed` entry is distinct from no entry.
    @Test
    func collapsedIsDistinctFromAbsent() {
        let state = MainHierarchyState()
        state.setExpansion(.collapsed, for: "group-1")
        #expect(state.expansion(for: "group-1") == .collapsed)
        #expect(state.expansion(for: "group-2") == nil)
    }

    /// Verifies that `.partial` survives repeated reads.
    @Test
    func partialSurvivesRepeatedReads() {
        let state = MainHierarchyState()
        state.setExpansion(.partial, for: "g")
        #expect(state.expansion(for: "g") == .partial)
        #expect(state.expansion(for: "g") == .partial)
    }

    /// Verifies that `.full` survives repeated reads.
    @Test
    func fullSurvivesRepeatedReads() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "g")
        #expect(state.expansion(for: "g") == .full)
        #expect(state.expansion(for: "g") == .full)
    }

    // MARK: - Job-state cleanup invariants (owned by setExpansion)

    /// Verifies that `setExpansion(.partial)` from `.full` clears nested jobs.
    ///
    /// Tests the production contract of `setExpansion`; callers must not
    /// need to manage this cleanup themselves.
    @Test
    func fullToPartialClearsJobs() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.setJobs([1, 2], for: "wf-a")

        state.setExpansion(.partial, for: "wf-a")

        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    /// Verifies that `setExpansion(.collapsed)` clears nested jobs.
    ///
    /// Tests the production contract of `setExpansion`; callers must not
    /// need to call `clearJobs` separately.
    @Test
    func explicitCollapseClearsJobs() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.setJobs([1, 2], for: "wf-a")

        state.setExpansion(.collapsed, for: "wf-a")

        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // MARK: - Job expansion accessors

    /// Verifies that job IDs are stored independently per workflow group.
    @Test
    func jobIDsStoredPerGroup() {
        let state = MainHierarchyState()
        state.setJobs([1, 2, 3], for: "wf-a")
        #expect(state.jobs(for: "wf-a") == [1, 2, 3])
    }

    /// Verifies that two workflow groups do not share nested job state.
    @Test
    func groupsDoNotShareJobState() {
        let state = MainHierarchyState()
        state.setJobs([1], for: "wf-a")
        state.setJobs([2], for: "wf-b")
        #expect(state.jobs(for: "wf-a") == [1])
        #expect(state.jobs(for: "wf-b") == [2])
    }

    /// Verifies that setting an empty job set returns an empty set on read.
    @Test
    func emptyJobSetIsEmpty() {
        let state = MainHierarchyState()
        state.setJobs([1], for: "wf-a")
        state.setJobs([], for: "wf-a")
        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    // MARK: - Status reconciliation: first observation

    /// Verifies that the first observation of `.inProgress` initializes `.partial`.
    @Test
    func firstInProgressInitializesPartial() {
        let state = MainHierarchyState()
        state.reconcile(status: .inProgress, for: "wf-a")
        #expect(state.expansion(for: "wf-a") == .partial)
    }

    /// Verifies that the first observation of a terminal status initializes `.collapsed`.
    @Test
    func firstSuccessInitializesCollapsed() {
        let state = MainHierarchyState()
        state.reconcile(status: .success, for: "wf-a")
        #expect(state.expansion(for: "wf-a") == .collapsed)
    }

    /// Verifies that the first observation of `.queued` initializes `.collapsed`.
    @Test
    func firstQueuedInitializesCollapsed() {
        let state = MainHierarchyState()
        state.reconcile(status: .queued, for: "wf-a")
        #expect(state.expansion(for: "wf-a") == .collapsed)
    }

    // MARK: - Status reconciliation: transitions while unmounted

    /// Verifies that `.inProgress` → `.success` while Main is unmounted collapses expansion.
    @Test
    func inProgressToSuccessWhileUnmountedCollapses() {
        let state = MainHierarchyState()
        state.reconcile(status: .inProgress, for: "wf-a") // partial
        state.setExpansion(.partial, for: "wf-a")

        // Simulate Main unmount: no view is observing status changes.
        // On remount, ActionRowView calls reconcile with the current status.
        state.reconcile(status: .success, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .collapsed)
    }

    /// Verifies that `.inProgress` → `.failed` while Main is unmounted collapses expansion.
    @Test
    func inProgressToFailedWhileUnmountedCollapses() {
        let state = MainHierarchyState()
        state.reconcile(status: .inProgress, for: "wf-a")

        state.reconcile(status: .failed, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .collapsed)
    }

    /// Verifies that `.collapsed` → `.inProgress` while Main is unmounted auto-expands to partial.
    @Test
    func queuedCollapsedToInProgressWhileUnmountedExpandsToPartial() {
        let state = MainHierarchyState()
        state.reconcile(status: .queued, for: "wf-a") // .collapsed

        state.reconcile(status: .inProgress, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .partial)
    }

    /// Verifies that a completed workflow that was explicitly expanded remains `.full`
    /// when no status transition occurred while Main was away.
    @Test
    func completedFullWithNoTransitionRemainsFullOnRemount() {
        let state = MainHierarchyState()
        state.reconcile(status: .success, for: "wf-a") // .collapsed
        state.setExpansion(.full, for: "wf-a")         // user tapped expand

        // Remount: status is still .success — no transition.
        state.reconcile(status: .success, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .full)
    }

    /// Verifies that a terminal → success transition (e.g. re-run) while unmounted
    /// does not collapse an explicitly expanded row (no inProgress previous).
    @Test
    func terminalToSuccessWithNoInProgressDoesNotCollapse() {
        let state = MainHierarchyState()
        state.reconcile(status: .failed, for: "wf-a")  // .collapsed
        state.setExpansion(.full, for: "wf-a")          // user expanded

        state.reconcile(status: .success, for: "wf-a")

        #expect(state.expansion(for: "wf-a") == .full)
    }

    /// Verifies that a terminal transition clears nested job IDs.
    @Test
    func inProgressToSuccessClearsNestedJobs() {
        let state = MainHierarchyState()
        state.reconcile(status: .inProgress, for: "wf-a")
        state.setJobs([1, 2], for: "wf-a")

        state.reconcile(status: .success, for: "wf-a")

        #expect(state.jobs(for: "wf-a").isEmpty)
    }

    /// Verifies that status entries are pruned when their workflow group is removed.
    @Test
    func retainGroupsPrunesStaleStatuses() {
        let state = MainHierarchyState()
        state.reconcile(status: .success, for: "wf-stale")
        state.retainGroups([])
        #expect(state.status(for: "wf-stale") == nil)
    }

    // MARK: - Pruning

    /// Verifies that `retainGroups` keeps current groups.
    @Test
    func retainGroupsKeepsCurrent() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.retainGroups(["wf-a"])
        #expect(state.expansion(for: "wf-a") == .full)
    }

    /// Verifies that `retainGroups` removes obsolete workflow expansion.
    @Test
    func retainGroupsRemovesObsoleteExpansion() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-stale")
        state.retainGroups([])
        #expect(state.expansion(for: "wf-stale") == nil)
    }

    /// Verifies that `retainGroups` removes obsolete nested job state.
    @Test
    func retainGroupsRemovesObsoleteJobs() {
        let state = MainHierarchyState()
        state.setJobs([1, 2], for: "wf-stale")
        state.retainGroups([])
        #expect(state.jobs(for: "wf-stale").isEmpty)
    }

    /// Verifies that reordering the same group IDs does not affect stored state.
    @Test
    func reorderingDoesNotAffectState() {
        let state = MainHierarchyState()
        state.setExpansion(.full, for: "wf-a")
        state.setExpansion(.partial, for: "wf-b")
        state.retainGroups(["wf-b", "wf-a"])
        #expect(state.expansion(for: "wf-a") == .full)
        #expect(state.expansion(for: "wf-b") == .partial)
    }

    // MARK: - Visible count

    /// Verifies that `visibleCount` defaults to 10.
    @Test
    func visibleCountDefaults() {
        let state = MainHierarchyState()
        #expect(state.visibleCount == 10)
    }

    /// Verifies that `visibleCount` survives mutation.
    @Test
    func visibleCountSurvivesMutation() {
        let state = MainHierarchyState()
        state.visibleCount = 25
        #expect(state.visibleCount == 25)
    }
}
