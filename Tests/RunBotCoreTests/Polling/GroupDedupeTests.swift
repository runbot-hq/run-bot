// GroupDedupeTests.swift
// RunBotCoreTests
//
// Regression coverage for #2684 / #2688:
// - Duplicate workflow rows on in-progress → success transition
// - Repo-qualified composite cache key
// - Stable group identity across run additions

import XCTest
@testable import RunBotCore

final class GroupDedupeTests: XCTestCase {

    // MARK: - Factory

    private func makeGroup(
        repo: String = "owner/repo",
        sha: String,
        event: String = "commit",
        runIDs: [Int],
        status: JobStatus = .inProgress
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
            normalizedEvent: event
        )
    }

    // MARK: - Tests

    /// A live entry and a completed entry for the same group must coalesce to one row.
    func testNoDuplicateOnCompletionTransition() {
        let live      = makeGroup(sha: "abc", runIDs: [100])
        let completed = makeGroup(sha: "abc", runIDs: [100, 101], status: .completed)
        let display   = [live, completed]
        let deduped   = Dictionary(
            display.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
        ).values
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(Set(deduped.map(\.id)).count, deduped.count,
                       "Display list must not contain duplicate ids")
    }

    /// Group id must stay identical after new runs are added to the same commit.
    func testIdentityStableAcrossRunAddition() {
        let before = makeGroup(sha: "abc", runIDs: [100])
        let after  = makeGroup(sha: "abc", runIDs: [100, 101])
        XCTAssertEqual(before.id, after.id)
    }

    /// push and workflow_dispatch on the same SHA are two distinct groups.
    func testEventSeparationPreserved() {
        let push   = makeGroup(sha: "abc", event: "commit",            runIDs: [100])
        let manual = makeGroup(sha: "abc", event: "workflow_dispatch", runIDs: [101])
        XCTAssertNotEqual(push.id, manual.id)
    }

    /// Same SHA + event under two different repos are two distinct groups.
    func testRepoSeparationPreserved() {
        let repoA = makeGroup(repo: "owner/repoA", sha: "abc", runIDs: [100])
        let repoB = makeGroup(repo: "owner/repoB", sha: "abc", runIDs: [101])
        XCTAssertNotEqual(repoA.id, repoB.id)
    }

    /// latestRunID 10 must beat latestRunID 9 in the tiebreak.
    func testNumericTiebreakCorrect() {
        let older = makeGroup(sha: "abc", runIDs: [9])
        let newer = makeGroup(sha: "abc", runIDs: [10])
        let winner = Dictionary(
            [older, newer].map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
        ).values.first!
        XCTAssertEqual(winner.latestRunID, 10)
    }

    /// Global invariant: any display slice derived from deduplication must have no duplicate ids.
    func testGlobalInvariantNoDuplicateIDs() {
        let groups: [WorkflowActionGroup] = [
            makeGroup(sha: "abc", runIDs: [100]),
            makeGroup(sha: "abc", runIDs: [101]),   // same key, newer run
            makeGroup(sha: "def", runIDs: [200]),
            makeGroup(repo: "owner/other", sha: "abc", runIDs: [300]),  // different repo
        ]
        let display = Dictionary(
            groups.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in lhs.latestRunID >= rhs.latestRunID ? lhs : rhs }
        ).values
        XCTAssertEqual(
            Set(display.map(\.id)).count, display.count,
            "Deduped display must have no duplicate ids"
        )
        // abc:commit and def:commit and owner/other:abc:commit = 3 unique groups
        XCTAssertEqual(display.count, 3)
    }

    /// compositeCacheKey static and instance overloads must agree.
    func testCompositeCacheKeyConsistency() {
        let group = makeGroup(repo: "owner/repo", sha: "deadbeef", event: "push", runIDs: [42])
        let staticKey = WorkflowActionGroup.compositeCacheKey(
            repo: "owner/repo", headSha: "deadbeef", normalizedEvent: "push")
        XCTAssertEqual(group.compositeCacheKey, staticKey)
        XCTAssertEqual(group.id, staticKey)
    }
}
