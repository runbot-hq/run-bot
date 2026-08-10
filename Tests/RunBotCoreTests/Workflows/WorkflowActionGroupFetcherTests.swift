// WorkflowActionGroupFetcherTests.swift
// RunBotCoreTests

import Foundation
import Testing
import os

import GitHubClient
@testable import RunBotCore

// MARK: - StubTransport

/// Minimal `GitHubTransportProtocol` stub for `WorkflowActionGroupFetcher` tests.
///
/// Responses are registered as an ordered array of `(prefix, Data)` pairs — the
/// *longest matching prefix* wins. When two registered prefixes have the same
/// length, the winning one is undefined because the input dictionary's iteration
/// order is unspecified. Test authors should ensure registered prefixes have
/// distinct lengths or non-overlapping URL paths to avoid ambiguity.
///
/// The responses array is immutable (set once at `init`), so `StubTransport` is
/// implicitly `Sendable`. The call counter uses `OSAllocatedUnfairLock` for
/// thread-safe concurrent access, following the project's established pattern
/// (see `ProcessRunner.swift`).
struct StubTransport: GitHubTransportProtocol {
  /// Ordered prefix → data pairs. Longest-prefix match wins.
  private let responses: [(prefix: String, data: Data)]

  /// Thread-safe call counter for `apiAsync` calls.
  private let apiCallCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)
  /// Thread-safe call counter for `raw` calls.
  private let rawCallCountLock = OSAllocatedUnfairLock<Int>(initialState: 0)

  /// The number of times `apiAsync` has been called. Thread-safe.
  var apiCallCount: Int { apiCallCountLock.withLock { $0 } }
  /// The number of times `raw` has been called. Thread-safe.
  var rawCallCount: Int { rawCallCountLock.withLock { $0 } }
  /// Total number of transport calls. Thread-safe.
  var callCount: Int { apiCallCount + rawCallCount }

  /// Creates a stub with the given endpoint-prefix → Data map.
  init(responses: [String: Data] = [:]) {
    // Sort longest prefix first so `apiAsync` picks the most specific match.
    // Same-length prefix ordering is undefined (input is a Dictionary).
    let sorted = responses.map { (prefix: $0.key, data: $0.value) }
      .sorted { $0.prefix.count > $1.prefix.count }
    // Detect same-length prefixes that share a common stem — these would be
    // ambiguous under longest-prefix matching. This is a low-cost safety net
    // for test authors; production code is unaffected.
    for i in 0..<max(0, sorted.count - 1) {
      let a = sorted[i]
      let b = sorted[i + 1]
      assert(
        a.prefix.count != b.prefix.count || !b.prefix.hasPrefix(a.prefix),
        "Ambiguous same-length prefix entries: \(sorted.map(\.prefix))")
    }
    self.responses = sorted
  }

  // Intentionally a computed property — each call returns a fresh, unconfigured
  // JSONDecoder. This is correct for a stateless test stub: no shared decoder
  // state can leak between calls. Do not change to a stored `let` unless the
  // protocol explicitly requires a shared, pre-configured instance.
  //
  // No divergence from a production pre-configured decoder is possible here:
  // StubTransport never decodes anything itself. Every response is pre-serialised
  // Data owned by the test fixture; WorkflowActionGroupFetcher decodes that Data
  // using its own internal decoder, not transport.decoder. The `decoder` property
  // on this stub satisfies the protocol requirement but is never invoked during
  // any test in this file.
  var decoder: JSONDecoder { JSONDecoder() }
  var logger: (any GitHubLogger)? { nil }

  func apiAsync(_ endpoint: String, timeout _: TimeInterval) async -> Data? {
    apiCallCountLock.withLock { $0 += 1 }
    return responses.first(where: { endpoint.hasPrefix($0.prefix) })?.data
  }

  func apiPaginated(_: String, timeout _: TimeInterval) async -> Data? { nil }
  func raw(_ endpoint: String, timeout _: TimeInterval) async -> Data? {
    rawCallCountLock.withLock { $0 += 1 }
    return responses.first(where: { endpoint.hasPrefix($0.prefix) })?.data
  }
  func post(_: String, body _: Data?, timeout _: TimeInterval) async -> Data? { nil }
  func put(_: String, body _: Data, timeout _: TimeInterval) async -> Data? { nil }
  func delete(_: String, timeout _: TimeInterval) async -> Bool { false }
  func cancelRun(runID _: Int, scope _: String) async -> Bool { false }
  func patchRunnerLabels(scope _: String, runnerID _: Int, labels _: [String]) async -> [String]? {
    nil
  }
  func fetchRegistrationToken(scope _: String) async -> String? { nil }
  func fetchRemovalToken(scope _: String) async -> String? { nil }
  func deleteRunnerByID(scope _: String, runnerID _: Int) async -> Bool { false }
}

// MARK: - JSON fixture helpers

private func envelope(key: String, _ values: [[String: Any]]) -> Data {
  let envelope: [String: Any] = [key: values]
  return (try? JSONSerialization.data(withJSONObject: envelope)) ?? Data()
}

private func withConclusion(_ d: inout [String: Any], _ conclusion: String?) {
  if let conclusion { d["conclusion"] = conclusion }
}

/// Builds a minimal workflow-run JSON fixture.
///
/// `event` defaults to `"push"`, which `groupEvent(_:)` normalises to `"commit"`.
/// Pass `event: "workflow_dispatch"` (or another non-commit value) to test
/// dispatch-triggered runs that must be placed in their own group.
private func minimalRun(
  id: Int, sha: String, status: String = "completed",
  conclusion: String? = "success",
  name: String = "CI",
  event: String = "push"
) -> [String: Any] {
  var d: [String: Any] = ["id": id, "head_sha": sha, "status": status, "name": name, "event": event]
  withConclusion(&d, conclusion)
  return d
}

private func minimalJob(
  id: Int, name: String = "build",
  status: String = "completed",
  conclusion: String? = "success",
  runID: Int = 0
) -> [String: Any] {
  var d: [String: Any] = ["id": id, "run_id": runID, "name": name, "status": status]
  withConclusion(&d, conclusion)
  return d
}

// MARK: - WorkflowActionGroupFetcherTests

@Suite("WorkflowActionGroupFetcher")
struct WorkflowActionGroupFetcherTests {
  /// Builds a concluded `WorkflowActionGroup` cache entry for the given SHA.
  /// Callers supply only the fields that vary between tests.
  ///
  /// `runID` is used to seed a single `WorkflowRunRef` so that `group.id`
  /// (derived as `runs.map { $0.id }.max() ?? 0`) is non-zero and unique per
  /// group. Without it, every helper-constructed group would have `id == "0"`,
  /// causing silent collisions in any future test that keys the cache by group ID.
  ///
  /// runs: [run] is intentional — group.id resolves to "0" for all fixtures here.
  /// Cache lookup in these tests is keyed by the cacheKey string, not by group.id,
  /// so identity collisions are benign. If you add tests that key by group.id,
  /// pass an explicit runID to avoid silent collisions.
  private func makeCachedGroup(
    sha: String,
    runID: Int = 1,
    title: String = "Cached commit",
    repo: String = "owner/repo",
    jobID: Int = 999,
    jobName: String = "cached-build",
    jobScope: String = "owner/repo",
    steps: [JobStep] = [],
    normalizedEvent: String = "commit"
  ) -> WorkflowActionGroup {
    let run = WorkflowRunRef(id: runID, name: "CI", status: .completed, conclusion: .success, htmlUrl: nil)
    return WorkflowActionGroup(
      headSha: sha,
      label: sha,
      title: title,
      headBranch: nil,
      repo: repo,
      runs: [run],
      jobs: [
        ActiveJob(
          id: jobID, name: jobName, status: .completed, htmlUrl: nil,
          conclusion: .success, isDimmed: false,
          runnerName: nil, scope: jobScope,
          startedAt: nil, completedAt: Date(), steps: steps
        )
      ],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      normalizedEvent: normalizedEvent
    )
  }

  private func makeTransport(with responses: [String: Data] = [:]) -> StubTransport {
    let e = envelope(key: "workflow_runs", [])
    var base: [String: Data] = [
      "repos/owner/repo/actions/runs?status=in_progress": e,
      "repos/owner/repo/actions/runs?status=queued": e,
      "repos/owner/repo/actions/runs?status=completed": e,
    ]
    for (k, v) in responses { base[k] = v }
    return StubTransport(responses: base)
  }

  /// Creates a `StubTransport` with a single run + its jobs endpoint, used by
  /// cache-bypass tests that need to verify re-fetching from the API.
  private func makeBypassTransport(sha: String, jobData: Data) -> StubTransport {
    makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success")
        ]),
      "repos/owner/repo/actions/runs/1/jobs": jobData,
    ])
  }

  /// Convenience overload: single concluded run with one completed live job.
  private func makeCompletedRunTransport(sha: String, liveJobID: Int = 888) -> StubTransport {
    makeBypassTransport(
      sha: sha,
      jobData: envelope(
        key: "jobs", [minimalJob(id: liveJobID, status: "completed", conclusion: "success")])
    )
  }

  // MARK: - Org scope guard

  /// Verifies that fetching with an org-only scope (no `/`) returns an empty array and makes no transport calls.
  @Test func fetchActionGroupsOrgScopeReturnsEmpty() async {
    let s = StubTransport()
    let f = WorkflowActionGroupFetcher(transport: s)
    let r = await f.fetch(for: "myorg")
    #expect(r.isEmpty)
    #expect(s.callCount == 0)
  }

  // MARK: - Empty API responses

  /// Verifies that when all three status endpoints return empty `workflow_runs` arrays, `fetch` returns an empty array.
  @Test func fetchActionGroupsAllEndpointsEmptyReturnsEmpty() async {
    let f = WorkflowActionGroupFetcher(transport: makeTransport())
    #expect(await f.fetch(for: "owner/repo").isEmpty)
  }

  /// Verifies that when the transport returns `nil` for all endpoints (simulating no network), `fetch` returns an empty array.
  @Test func fetchActionGroupsNilResponsesReturnsEmpty() async {
    let f = WorkflowActionGroupFetcher(transport: StubTransport())
    #expect(await f.fetch(for: "owner/repo").isEmpty)
  }

  // MARK: - Grouping by head_sha

  /// Verifies that two runs sharing the same `head_sha` and event are merged into a single `WorkflowActionGroup` with both runs and deduplicated jobs.
  @Test func fetchActionGroupsTwoRunsSameShaProducesOneGroup() async {
    let sha = "abc1234567890"
    let runs = [
      minimalRun(id: 1, sha: sha, status: "in_progress", conclusion: nil, name: "build"),
      minimalRun(id: 2, sha: sha, status: "in_progress", conclusion: nil, name: "test"),
    ]
    let j = envelope(key: "jobs", [minimalJob(id: 101), minimalJob(id: 102)])
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(key: "workflow_runs", runs),
      "repos/owner/repo/actions/runs/1/jobs": j,
      "repos/owner/repo/actions/runs/2/jobs": j,
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.count == 1)
    #expect(r.first?.headSha == sha)
    #expect(r.first?.runs.count == 2)
    // Both runs return the same two jobs (101, 102); verify dedup produces exactly 2, not 4.
    #expect(r.first?.jobs.count == 2)
  }

  /// Verifies that two runs with different `head_sha` values produce two separate `WorkflowActionGroup` entries.
  @Test func fetchActionGroupsTwoRunsDifferentShaProducesTwoGroups() async {
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: "aaa111", status: "in_progress", conclusion: nil),
          minimalRun(id: 2, sha: "bbb222", status: "in_progress", conclusion: nil),
        ]),
      "repos/owner/repo/actions/runs/1/jobs": envelope(key: "jobs", []),
      "repos/owner/repo/actions/runs/2/jobs": envelope(key: "jobs", []),
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.count == 2)
    #expect(Set(r.map { $0.headSha }) == ["aaa111", "bbb222"])
  }

  /// Verifies that a `workflow_dispatch` run on the same SHA as a `push` run
  /// produces two separate groups rather than being merged into one.
  @Test func fetchActionGroupsDispatchRunOnSameShaProducesSeparateGroup() async {
    let sha = "shared999"
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=completed": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success", name: "CI", event: "push"),
          minimalRun(id: 2, sha: sha, status: "completed", conclusion: "success", name: "Publish", event: "workflow_dispatch"),
        ]),
      "repos/owner/repo/actions/runs/1/jobs": envelope(key: "jobs", [minimalJob(id: 10)]),
      "repos/owner/repo/actions/runs/2/jobs": envelope(key: "jobs", [minimalJob(id: 20)]),
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.count == 2, "push and workflow_dispatch runs on the same SHA must be in separate groups")
    let pushGroup = r.first(where: { $0.runs.first?.name == "CI" })
    let dispatchGroup = r.first(where: { $0.runs.first?.name == "Publish" })
    #expect(pushGroup != nil)
    #expect(dispatchGroup != nil)
    #expect(pushGroup?.jobs.first?.id == 10)
    #expect(dispatchGroup?.jobs.first?.id == 20)
  }

  // MARK: - Sort order

  /// Verifies that in-progress groups are sorted before completed groups in the returned array.
  @Test func fetchActionGroupsMixedStatusesInProgressSortsFirst() async {
    let j = envelope(key: "jobs", [])
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: "aaainprogress", status: "in_progress", conclusion: nil)
        ]),
      "repos/owner/repo/actions/runs?status=completed": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 2, sha: "bbbcompleted", status: "completed", conclusion: "success")
        ]),
      "repos/owner/repo/actions/runs/1/jobs": j,
      "repos/owner/repo/actions/runs/2/jobs": j,
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.count == 2)
    #expect(r.first?.headSha == "aaainprogress")
    #expect(r.last?.headSha == "bbbcompleted")
  }

  // MARK: - Cache hit

  /// Verifies that a concluded cache entry for a given SHA is served directly without re-fetching the `/jobs` endpoint (only 3 status calls are made).
  ///
  /// The cache key is `"\(sha):commit"` because the fixture run uses `event: "push"`,
  /// which `groupEvent(_:)` normalises to `"commit"`.
  @Test func fetchActionGroupsConcludedCacheEntryJobsNotRefetched() async {
    let sha = "cachedsha"
    let cacheKey = "owner/repo:\(sha):commit"
    let cached = makeCachedGroup(sha: sha)
    // No /jobs endpoints registered — fetcher must not call them.
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success")
        ])
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo", cache: [cacheKey: cached])
    #expect(r.count == 1)
    #expect(r.first?.jobs.first?.id == 999)
    #expect(t.callCount == 3)
  }

  /// Verifies that a cached entry whose job is concluded but has an in-progress step bypasses the cache and re-fetches jobs from the API (stale-step guard).
  @Test func fetchActionGroupsConcludedCacheWithInProgressStepRefetchesJobs() async {
    // A cached entry where a job is concluded but a step is still in-progress
    // must NOT serve from cache — the stale-step guard re-fetches via API.
    let sha = "staledash"
    let cacheKey = "owner/repo:\(sha):commit"
    let cached = makeCachedGroup(
      sha: sha,
      title: "Stale step commit",
      jobID: 888,
      jobName: "stale-build",
      steps: [JobStep(id: 1, name: "lint", status: .inProgress)]
    )
    let t = makeCompletedRunTransport(sha: sha)
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo", cache: [cacheKey: cached])
    #expect(r.count == 1)
    // 3 status calls + 1 jobs-list call = 4 (not 3 — cache was bypassed)
    #expect(t.callCount == 4)
  }

  // MARK: - Refresh cap

  /// Verifies that individual job refresh calls are capped at `maxRefreshConcurrency` — when a run has 4 in-progress jobs, only 3 individual `/actions/jobs/{id}` calls are dispatched.
  @Test func fetchActionGroupsInProgressJobsCappedAtMaxRefreshConcurrency() async {
    // When a single run has 4 in-progress jobs but maxRefreshConcurrency is 3,
    // only 3 individual /actions/jobs/{id} refresh calls are dispatched.
    // The 4th job silently uses stale data — verified by the call count not reaching 8.
    let runID = 1
    let sha = "capcap"
    let inProgressJobs = (1...4).map { i in
      minimalJob(id: 100 + i, status: "in_progress", conclusion: nil)
    }
    var extras: [String: Data] = [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: runID, sha: sha, status: "in_progress", conclusion: nil)
        ]),
      "repos/owner/repo/actions/runs/\(runID)/jobs": envelope(key: "jobs", inProgressJobs),
    ]
    // Register individual job endpoints for the first 3 jobs only.
    // Job 104 is deliberately unregistered — if the cap fails, the fetcher
    // will call it and get nil; the callCount assertion detects the difference.
    for i in 1...3 {
      let job = minimalJob(id: 100 + i, status: "in_progress", conclusion: nil)
      extras["repos/owner/repo/actions/jobs/\(100 + i)"] =
        (try? JSONSerialization.data(withJSONObject: job)) ?? Data()
    }
    let t = makeTransport(with: extras)
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.count == 1)
    #expect(r.first?.jobs.count == 4)
    // 3 status calls + 1 jobs-list call + 3 refresh calls = 7 (not 8)
    #expect(t.callCount == 7)
  }

  // MARK: - Cross-scope cache miss

  /// Verifies that a concluded cache entry whose `repo` field does not match the current fetch scope is not served — the fetcher re-fetches from the API and returns the live job, not the cached one.
  @Test func fetchActionGroupsCachedEntryForDifferentRepoNotServedAsCacheHit() async {
    // A concluded cache entry whose `repo` doesn't match the fetch scope must
    // NOT be served — the `cached.repo == scope` guard must fire and re-fetch.
    let sha = "crossreposha"
    let cacheKey = "owner/repo:\(sha):commit"
    let cached = makeCachedGroup(
      sha: sha,
      title: "Other repo commit",
      repo: "owner/other-repo",
      jobID: 777,
      jobName: "other-build",
      jobScope: "owner/other-repo"
    )
    let t = makeCompletedRunTransport(sha: sha)
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo", cache: [cacheKey: cached])
    #expect(r.count == 1)
    // Cache was bypassed — live job id 888 is returned, not cached id 777.
    #expect(r.first?.jobs.first?.id == 888)
    // 3 status calls + 1 jobs-list call = 4 (not 3 — cache was not served)
    #expect(t.callCount == 4)
  }

  // MARK: - Repo label

  /// Verifies that the `repo` field on a returned group matches the scope string passed to `fetch(for:)`.
  @Test func fetchActionGroupsSingleRunGroupHasCorrectRepoScope() async {
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [
          minimalRun(id: 1, sha: "scopecheck", status: "in_progress", conclusion: nil)
        ]),
      "repos/owner/repo/actions/runs/1/jobs": envelope(key: "jobs", []),
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    #expect(r.first?.repo == "owner/repo")
  }

  // MARK: - Three-way status-bucket merge (#1983 Step 6)

  /// Verifies the three-way merge path: each of the three status endpoints
  /// (`in_progress`, `queued`, `completed`) returns a run with a *distinct* SHA.
  ///
  /// The production poll always calls all three buckets concurrently and merges
  /// the results by `head_sha`. This test ensures that:
  /// 1. All three groups appear in the result (no bucket is silently dropped).
  /// 2. Each group carries the correct `JobStatus` reflecting its source bucket.
  /// 3. No cross-SHA merging occurs (each SHA stays in its own group).
  @Test func fetchActionGroupsThreeWayBucketMergeProducesThreeDistinctGroups() async {
    let shaInProgress = "sha-inprogress-001"
    let shaQueued     = "sha-queued-002"
    let shaCompleted  = "sha-completed-003"
    let j = envelope(key: "jobs", [])
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [minimalRun(id: 10, sha: shaInProgress, status: "in_progress", conclusion: nil)]),
      "repos/owner/repo/actions/runs?status=queued": envelope(
        key: "workflow_runs",
        [minimalRun(id: 20, sha: shaQueued, status: "queued", conclusion: nil)]),
      "repos/owner/repo/actions/runs?status=completed": envelope(
        key: "workflow_runs",
        [minimalRun(id: 30, sha: shaCompleted, status: "completed", conclusion: "success")]),
      "repos/owner/repo/actions/runs/10/jobs": j,
      "repos/owner/repo/actions/runs/20/jobs": j,
      "repos/owner/repo/actions/runs/30/jobs": j,
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")

    // All three distinct SHAs must produce exactly three groups.
    #expect(r.count == 3, "Three distinct SHAs must produce exactly three groups")
    let shas = Set(r.map { $0.headSha })
    #expect(shas == [shaInProgress, shaQueued, shaCompleted],
            "Each SHA must appear exactly once")

    // Each group must carry the run status from its source bucket.
    // `group` is a local lookup closure scoped to this test — not a type or namespace.
    let group = { (sha: String) in r.first(where: { $0.headSha == sha }) }
    #expect(
      group(shaInProgress)?.runs.first?.status == .inProgress,
      "in_progress bucket run must have status .inProgress")
    #expect(
      group(shaQueued)?.runs.first?.status == .queued,
      "queued bucket run must have status .queued")
    #expect(
      group(shaCompleted)?.runs.first?.status == .completed,
      "completed bucket run must have status .completed")
  }

  // MARK: - Composite cache key (#2444)

  /// Verifies that a concluded cache entry keyed by the composite `"repo:sha:event"` string
  /// is served without re-fetching jobs (regression guard for #2444, updated for #2688).
  ///
  /// Prior to #2444, `makeShaKeyedCache` keyed by bare `headSha`; updated to `sha:event` in
  /// #2444, then extended to `repo:sha:event` in #2688 to prevent cross-scope collisions.
  @Test func fetchActionGroupsCompositeCacheKeyHitServesJobsWithoutAPICall() async {
    let sha = "compositehit"
    // Cache key must match what `buildActionGroup` passes to `fetchJobsForGroup`:
    // `groupKey.cacheKey` == `"\(repo):\(headSha):\(groupEvent(event))"`, and
    // `groupEvent("push")` == `"commit"`.
    let cacheKey = "owner/repo:\(sha):commit"
    let cached = makeCachedGroup(sha: sha, jobID: 42)
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": envelope(
        key: "workflow_runs",
        [minimalRun(id: 1, sha: sha, status: "completed", conclusion: "success", event: "push")]),
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo", cache: [cacheKey: cached])
    #expect(r.count == 1)
    // Cache was served — job id 42 (not a live fetch).
    #expect(r.first?.jobs.first?.id == 42)
    // 3 status calls only — no /jobs endpoint hit.
    #expect(t.callCount == 3)
  }

  // MARK: - Title derivation (#2690)

  /// Regression guard for #2690: the group title must be the commit subject for
  /// pull_request runs, and display_title for workflow_dispatch events.
  ///
  /// Three cases:
  /// 1. Mixed group (push + pull_request runs on same SHA): commit subject wins.
  /// 2. PR-only group (pull_request run only, no push run): commit subject wins,
  ///    body text after first newline must be stripped.
  /// 3. Workflow_dispatch group: display_title ("Publish") wins over commit subject.
  ///    This case fails on the head_commit-first approach from ab6927c9.
  @Test func fetchActionGroupsCommitSubjectUsedNotPRTitle() async {
    // MARK: Case 1 — mixed push + pull_request group
    let mixedSha = "titleregressionsha"
    var pushRun = minimalRun(id: 100, sha: mixedSha, status: "in_progress", conclusion: nil, event: "push")
    pushRun["display_title"] = "PR: some pull request title"
    pushRun["head_commit"] = ["message": "fix: the real commit subject"]
    var prRun = minimalRun(id: 101, sha: mixedSha, status: "in_progress", conclusion: nil, event: "pull_request")
    prRun["display_title"] = "PR: some pull request title"
    prRun["head_commit"] = ["message": "fix: the real commit subject"]
    // Serve PR run first so decode order cannot accidentally save us.
    let t1 = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": (
        try? JSONSerialization.data(
          withJSONObject: ["workflow_runs": [prRun, pushRun]])) ?? Data(),
      "repos/owner/repo/actions/runs/100/jobs": envelope(key: "jobs", [minimalJob(id: 1, runID: 100)]),
      "repos/owner/repo/actions/runs/101/jobs": envelope(key: "jobs", [minimalJob(id: 2, runID: 101)]),
    ])
    let r1 = await WorkflowActionGroupFetcher(transport: t1).fetch(for: "owner/repo")
    #expect(r1.count == 1, "push + pull_request on same SHA must form one group")
    #expect(
      r1.first?.title.hasPrefix("fix: the real commit") == true,
      "Case 1 (mixed): expected commit subject, got: \(r1.first?.title ?? "nil")")

    // MARK: Case 2 — PR-only group (no push run — the failing case in the screenshot)
    let prOnlySha = "pronlyregressionsha"
    var prOnlyRun = minimalRun(id: 200, sha: prOnlySha, status: "in_progress", conclusion: nil, event: "pull_request")
    prOnlyRun["display_title"] = "PR: some pull request title"
    // head_commit carries commit subject with body text — body must be stripped.
    prOnlyRun["head_commit"] = ["message": "fix: the real commit subject\n\nbody text that must not appear"]
    let t2 = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": (
        try? JSONSerialization.data(
          withJSONObject: ["workflow_runs": [prOnlyRun]])) ?? Data(),
      "repos/owner/repo/actions/runs/200/jobs": envelope(key: "jobs", [minimalJob(id: 3, runID: 200)]),
    ])
    let r2 = await WorkflowActionGroupFetcher(transport: t2).fetch(for: "owner/repo")
    #expect(r2.count == 1, "PR-only group must produce one row")
    #expect(
      r2.first?.title == "fix: the real commit subject",
      "Case 2 (PR-only): expected commit subject without body, got: \(r2.first?.title ?? "nil")")
    #expect(
      r2.first?.title.contains("PR:") == false,
      "Case 2: PR title must not appear in row label")

    // MARK: Case 3 — workflow_dispatch group (display_title must win)
    let dispatchSha = "dispatchtitlesha"
    var dispatchRun = minimalRun(id: 300, sha: dispatchSha, status: "in_progress", conclusion: nil, event: "workflow_dispatch")
    dispatchRun["display_title"] = "Publish"
    dispatchRun["head_commit"] = ["message": "chore: bump version"]
    let t3 = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": (
        try? JSONSerialization.data(
          withJSONObject: ["workflow_runs": [dispatchRun]])) ?? Data(),
      "repos/owner/repo/actions/runs/300/jobs": envelope(key: "jobs", [minimalJob(id: 4, runID: 300)]),
    ])
    let r3 = await WorkflowActionGroupFetcher(transport: t3).fetch(for: "owner/repo")
    #expect(r3.count == 1, "workflow_dispatch group must produce one row")
    #expect(
      r3.first?.title == "Publish",
      "Case 3 (workflow_dispatch): expected display_title \"Publish\", got: \(r3.first?.title ?? "nil")")
  }

  // NOTE: Cross-event eviction (fetchActionGroupsFreshPushDoesNotEvictDispatchCacheEntry)
  // is intentionally not tested at this layer. evictFreshShas lives in PollResultBuilder,
  // not in the fetcher — that regression is covered in PollResultBuilderEvictionTests.

  /// Verifies that a run JSON object missing the `event` key still decodes cleanly
  /// and is grouped under the `"push"` → `"commit"` default (regression guard for #2444
  /// secondary fix: `RunPayload.event` is now `String?`).
  @Test func fetchActionGroupsMissingEventFieldDefaultsToCommitGroup() async {
    let sha = "noeventsha"
    // Build a run fixture without the "event" key — simulates an unusual API response.
    var runDict: [String: Any] = ["id": 9, "head_sha": sha, "status": "completed", "name": "CI"]
    runDict["conclusion"] = "success"
    let t = makeTransport(with: [
      "repos/owner/repo/actions/runs?status=in_progress": (
        try? JSONSerialization.data(withJSONObject: ["workflow_runs": [runDict]])) ?? Data(),
      "repos/owner/repo/actions/runs/9/jobs": envelope(key: "jobs", [minimalJob(id: 3)]),
    ])
    let f = WorkflowActionGroupFetcher(transport: t)
    let r = await f.fetch(for: "owner/repo")
    // Must produce one group; must not crash or return empty.
    #expect(r.count == 1)
    // The group is bucketed under the "push" default → normalised to "commit".
    #expect(r.first?.normalizedEvent == "commit")
  }
}
