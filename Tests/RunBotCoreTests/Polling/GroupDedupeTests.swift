// GroupDedupeTests.swift
// RunBotCoreTests
//
// Regression coverage for #2684 / #2688 / #2690:
// - Duplicate workflow rows on in-progress → success transition
// - Repo-qualified composite cache key
// - Stable group identity across run additions
// - makeShaKeyedCache numeric tiebreak
//
// Uses swift-testing (@Test / #expect) consistent with the rest of the suite.

import Foundation
import Testing
@testable import RunBotCore

// MARK: - Factory

private func makeGroup(
    repo: String = "owner/repo",
    sha: String,
    event: String = "commit",
    runIDs: [Int],
    status: JobStatus = JobStatus.inProgress,
    createdAt: Date? = nil
) -> WorkflowActionGroup {
    let runs = runIDs.map {
        WorkflowRunRef(id: $0, name: "CI", status: status, conclusion: nil, htmlUrl: nil)
    }
    return WorkflowActionGroup(
        headSha: sha,
        label: String(sha.prefix(7)),
        title: "test commit",
        headBranch: "main",
        repo: repo,
        runs: runs,
        createdAt: createdAt,
        normalizedEvent: event
    )
}

// MARK: - Model identity

@Suite("WorkflowActionGroup identity")
struct GroupIdentityTests {

    /// Group id must stay identical after new runs are added to the same commit.
    @Test func identityStableAcrossRunAddition() {
        let before = makeGroup(sha: "abc", runIDs: [100])
        let after  = makeGroup(sha: "abc", runIDs: [100, 101])
        #expect(before.id == after.id)
    }

    /// push and workflow_dispatch on the same SHA are two distinct groups.
    @Test func eventSeparationPreserved() {
        let push   = makeGroup(sha: "abc", event: "commit",            runIDs: [100])
        let manual = makeGroup(sha: "abc", event: "workflow_dispatch", runIDs: [101])
        #expect(push.id != manual.id)
    }

    /// Same SHA + event under two different repos are two distinct groups.
    @Test func repoSeparationPreserved() {
        let repoA = makeGroup(repo: "owner/repoA", sha: "abc", runIDs: [100])
        let repoB = makeGroup(repo: "owner/repoB", sha: "abc", runIDs: [101])
        #expect(repoA.id != repoB.id)
    }

    /// compositeCacheKey static and instance overloads must agree.
    @Test func compositeCacheKeyConsistency() {
        let group = makeGroup(repo: "owner/repo", sha: "deadbeef", event: "push", runIDs: [42])
        let staticKey = WorkflowActionGroup.compositeCacheKey(
            repo: "owner/repo", headSha: "deadbeef", normalizedEvent: "push")
        #expect(group.compositeCacheKey == staticKey)
        #expect(group.id == staticKey)
    }
}

// MARK: - Display pipeline dedupe (exercises PollResultBuilder.buildGroupDisplay)

@Suite("Group display dedupe")
struct GroupDisplayDedupeTests {

    /// A live in-progress entry and a completed cache entry for the same composite key
    /// must produce exactly one row in buildGroupDisplay — no duplicate (#2688).
    @Test func noDuplicateRowOnCompletionTransition() {
        let live      = makeGroup(sha: "abc", runIDs: [100], status: JobStatus.inProgress)
        let completed = makeGroup(sha: "abc", runIDs: [100, 101], status: JobStatus.completed)
            .copying(isDimmed: true)
        let cache: [String: WorkflowActionGroup] = [completed.compositeCacheKey: completed]
        let display = PollResultBuilder.buildGroupDisplay(live: [live], cache: cache)
        #expect(display.count == 1)
    }

    /// When liveGroups contains two entries with the same composite id (transitional
    /// duplicate during a poll), the entry with the higher latestRunID wins.
    @Test func dedupeDropsLowerLatestRunID() {
        let older = makeGroup(sha: "abc", runIDs: [100], status: JobStatus.inProgress)
        let newer = makeGroup(sha: "abc", runIDs: [101], status: JobStatus.inProgress)
        let deduped = Dictionary(
            [older, newer].map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
        ).values
        let display = PollResultBuilder.buildGroupDisplay(live: Array(deduped), cache: [:])
        #expect(display.count == 1)
        #expect(display.first?.latestRunID == 101)
    }

    /// Global display invariant: no two rows share an id.
    @Test func globalInvariantNoDuplicateIDs() {
        let groups: [WorkflowActionGroup] = [
            makeGroup(sha: "abc", runIDs: [100], status: JobStatus.inProgress),
            makeGroup(sha: "def", runIDs: [200], status: JobStatus.inProgress),
            makeGroup(repo: "owner/other", sha: "abc", runIDs: [300], status: JobStatus.inProgress),
        ]
        let display = PollResultBuilder.buildGroupDisplay(live: groups, cache: [:])
        let ids = display.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(display.count == 3)
    }
}

// MARK: - makeShaKeyedCache tiebreak

@Suite("PollResultBuilder.makeShaKeyedCache")
struct MakeShaKeyedCacheTests {

    /// Regression guard: when the cache contains two entries sharing the same
    /// compositeCacheKey, makeShaKeyedCache must keep the one with the higher
    /// latestRunID — not the lexicographically larger key ("9" > "10" in strings).
    @Test func numericTiebreakCorrect() {
        let winner = makeGroup(sha: "abc", runIDs: [10])  // latestRunID == 10
        let loser  = makeGroup(sha: "abc", runIDs: [9])   // latestRunID == 9
        let cache: [String: WorkflowActionGroup] = [
            "key-a": winner,
            "key-b": loser,
        ]
        let result = PollResultBuilder.makeShaKeyedCache(cache)
        let entry = result[winner.compositeCacheKey]
        #expect(entry != nil)
        #expect(entry?.latestRunID == 10)
    }

}
