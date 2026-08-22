// RunBotCoreTests.swift
// RunBotCoreTests
import Foundation
import GitHubClient
import RunBotCore
import Testing

// MARK: - Model elapsed integration

@Suite("ModelElapsedIntegrationTests")
struct ModelElapsedIntegrationTests {

    /// startedAt takes precedence; createdAt is the fallback for running jobs.
    @Test func activeJobElapsedUsesJobTimingFallbacks() {
        let now = Date(timeIntervalSinceReferenceDate: 20_000)

        let started = ActiveJob(id: 1, name: "started", status: "in_progress",
                                startedAt: now.addingTimeInterval(-90))
        let created = ActiveJob(id: 2, name: "created", status: "in_progress",
                                createdAt: now.addingTimeInterval(-60))

        #expect(started.elapsed(now: now) == "01:30")
        #expect(created.elapsed(now: now) == "01:00")
    }

    /// A step maps its own timestamps and completion into the shared formatter.
    @Test func stepElapsedUsesStepTiming() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let end   = start.addingTimeInterval(60)
        let step  = GitHubStep(id: 1, name: "S", status: "completed",
                               startedAt: start, completedAt: end)
        #expect(step.elapsed == "01:00")
    }
}

// MARK: - ActiveJob.isLocalRunner

@Suite("ActiveJob.isLocalRunner")
struct ActiveJobIsLocalRunnerTests {

  /// Classification matrix: nil, every hosted-prefix family (case-insensitive),
  /// and an arbitrary self-hosted name. The forwarding itself is trivial; the
  /// hosted prefixes are the contract worth pinning.
  @Test func runnerNameClassification() {
    let cases: [(name: String?, expected: Bool?)] = [
      (nil,                          nil),
      ("ubuntu-latest",              false),
      ("macos-14",                   false),
      ("windows-2022",               false),
      ("buildjet-4vcpu-ubuntu-2204", false),
      ("depot-ubuntu-22.04",         false),
      ("GitHub Actions 12",          false),
      ("UBUNTU-LATEST",              false),
      ("office-mac-mini",            true)
    ]
    for testCase in cases {
      let job = ActiveJob(id: 1, name: "job", status: "completed", runnerName: testCase.name)
      #expect(job.isLocalRunner == testCase.expected,
              "runnerName=\(String(describing: testCase.name))")
    }
  }
}

// MARK: - RunnerModel.displayStatus

@Suite("RunnerModel.displayStatus")
struct RunnerModelDisplayStatusTests {

  /// Verifies that a running runner reports `"running"` as its display status.
  @Test func displayStatusRunning() {
    #expect(makeRunnerModel(isRunning: true).displayStatus == "running")
  }

  /// Verifies that a runner that is both running and busy reports `"busy"` as its display status.
  @Test func displayStatusBusy() {
    #expect(makeRunnerModel(isRunning: true, isBusy: true).displayStatus == "busy")
  }

  /// Verifies that a non-running runner with GitHub status `.online` reports `"online"`.
  @Test func displayStatusOnline() {
    #expect(makeRunnerModel(isRunning: false, githubStatus: .online).displayStatus == "online")
  }

  /// Verifies that a non-running runner with GitHub status `.offline` reports `"offline"`.
  @Test func displayStatusOffline() {
    #expect(makeRunnerModel(isRunning: false, githubStatus: .offline).displayStatus == "offline")
  }

  /// Verifies that a lifecycle warning string takes priority over the running state in display status.
  @Test func displayStatusLifecycleWarningTakesPriority() {
    let runner = makeRunnerModel(isRunning: true, lifecycleWarning: "update required")
    #expect(runner.displayStatus == "update required")
  }

  /// Verifies that a non-running runner whose GitHub status is `.busy` reports `"busy"`.
  @Test func displayStatusBusyGithubStatusWhenNotRunning() {
    #expect(makeRunnerModel(isRunning: false, githubStatus: .busy).displayStatus == "busy")
  }

  /// Verifies that an unknown GitHub status falls back to `"offline"` as the display status.
  @Test func displayStatusDefaultsToOfflineForUnknownStatus() {
    #expect(
      makeRunnerModel(isRunning: false, githubStatus: .unknown("draining")).displayStatus
        == "offline")
  }
}

// MARK: - RunnerModel.statusColor

@Suite("RunnerModel.statusColor")
struct RunnerModelStatusColorTests {

  /// Verifies that a running runner's status color is `.running`.
  @Test func statusColorRunning() {
    #expect(makeRunnerModel(isRunning: true).statusColor == .running)
  }

  /// Verifies that a running and busy runner's status color is `.busy`.
  @Test func statusColorBusy() {
    #expect(makeRunnerModel(isRunning: true, isBusy: true).statusColor == .busy)
  }

  /// Verifies that a non-running runner with GitHub status `.online` receives the `.idle` color.
  @Test func statusColorGithubOnlineIsIdle() {
    #expect(makeRunnerModel(isRunning: false, githubStatus: .online).statusColor == .idle)
  }

  /// Verifies that a non-running runner with GitHub status `.offline` receives the `.offline` color.
  @Test func statusColorOffline() {
    #expect(makeRunnerModel(isRunning: false, githubStatus: .offline).statusColor == .offline)
  }

  /// Verifies that a lifecycle warning overrides the normal running color and returns `.offline`.
  @Test func statusColorLifecycleWarning() {
    #expect(
      makeRunnerModel(isRunning: true, lifecycleWarning: "restart failed").statusColor == .offline)
  }

  /// Verifies that an unknown GitHub status results in the `.offline` status color.
  @Test func statusColorUnknownGithubStatus() {
    #expect(
      makeRunnerModel(isRunning: false, githubStatus: .unknown("draining")).statusColor == .offline)
  }
}

// MARK: - PollResultBuilder (pure logic)

@Suite("PollResultBuilder")
struct PollResultBuilderTests {

  // MARK: trimJobCache

  /// Verifies that `trimJobCache` evicts the oldest (lowest `completedDate`) entry when the cache exceeds the limit.
  @Test func trimJobCacheRemovesOldestWhenOverLimit() {
    var cache: [Int: ActiveJob] = [
      1: ActiveJob(
        id: 1, name: "A", status: "completed",
        completedAt: Date(timeIntervalSinceReferenceDate: 100)),
      2: ActiveJob(
        id: 2, name: "B", status: "completed",
        completedAt: Date(timeIntervalSinceReferenceDate: 200)),
      3: ActiveJob(
        id: 3, name: "C", status: "completed",
        completedAt: Date(timeIntervalSinceReferenceDate: 300)),
      4: ActiveJob(
        id: 4, name: "D", status: "completed",
        completedAt: Date(timeIntervalSinceReferenceDate: 400)),
    ]
    PollResultBuilder.trimJobCache(&cache, limit: 3)
    #expect(cache.count == 3)
    #expect(cache[1] == nil, "Oldest entry should be evicted")
  }

  /// Verifies that `trimJobCache` is a no-op when the cache is already at or below the limit.
  @Test func trimJobCacheNoopWhenUnderLimit() {
    var cache: [Int: ActiveJob] = [
      1: ActiveJob(id: 1, name: "A", status: "completed"),
      2: ActiveJob(id: 2, name: "B", status: "completed"),
    ]
    PollResultBuilder.trimJobCache(&cache, limit: 3)
    #expect(cache.count == 2)
  }

  /// Verifies that `trimJobCache` retains the entry with a distinct (later) `completedDate` when
  /// two entries share the same `completedDate` and exactly one must be evicted.
  ///
  /// The production sort is `completedDate` descending with no explicit secondary key.
  /// The tie-break between the two equal-dated entries (id 1 vs id 2) is deliberately not
  /// asserted: `trimJobCache` sorts the values of a `[Int: ActiveJob]` Dictionary, which has
  /// no guaranteed iteration order — the relative pre-sort position of the equal-dated entries
  /// is undefined, so pinning which one survives would be asserting an implementation detail
  /// that is not contractually guaranteed and could change across Swift runtime versions.
  /// This test only pins that the uniquely-dated entry is always retained and that the result
  /// count is exactly `limit`.
  ///
  /// Note: `ActiveJob(id:name:status:completedAt:)` is a test-only convenience init defined in
  /// `TestModelHelpers.swift`. The production model exposes `completedDate: Date?` (computed);
  /// the helper accepts `completedAt: Date?` and ISO-encodes it into the underlying `GitHubJob`.
  /// The call below is not a type mismatch — it is intentional and correct.
  @Test func trimJobCacheEqualCompletedDatesRetainsUniqueDateEntry() {
    let sharedDate = Date(timeIntervalSinceReferenceDate: 500)
    let laterDate  = Date(timeIntervalSinceReferenceDate: 600)
    var cache: [Int: ActiveJob] = [
      1: ActiveJob(
        id: 1, name: "A", status: "completed", completedAt: sharedDate),
      2: ActiveJob(
        id: 2, name: "B", status: "completed", completedAt: sharedDate),
      3: ActiveJob(
        id: 3, name: "C", status: "completed", completedAt: laterDate),
    ]
    PollResultBuilder.trimJobCache(&cache, limit: 2)
    // The entry with the uniquely later date must always survive.
    #expect(cache[3] != nil, "Entry with the most-recent completedDate must be retained")
    // Exactly `limit` entries must remain.
    #expect(cache.count == 2, "Cache must be trimmed to exactly the limit")
  }

  // MARK: buildJobDisplay

  /// Verifies that `buildJobDisplay` places live (in-progress) jobs before cached (completed) jobs.
  @Test func buildJobDisplayLiveJobsFirst() {
    let live: [ActiveJob] = [
      ActiveJob(id: 10, name: "Live", status: "in_progress")
    ]
    let cache: [Int: ActiveJob] = [
      20: ActiveJob(id: 20, name: "Done", status: "completed", conclusion: "success")
    ]
    let display = PollResultBuilder.buildJobDisplay(live: live, cache: cache)
    #expect(display.first?.id == 10)
    #expect(display.contains(where: { $0.id == 20 }))
  }

  /// Verifies that `buildJobDisplay` returns an empty array when both live jobs and the cache are empty.
  @Test func buildJobDisplayEmptyLiveAndCacheIsEmpty() {
    let display = PollResultBuilder.buildJobDisplay(live: [], cache: [:])
    #expect(display.isEmpty)
  }

  /// Verifies that `buildJobDisplay` does not cap live jobs at the cache limit — live jobs must always be shown in full.
  @Test func buildJobDisplayDoesNotCapLiveJobsAtCacheLimit() {
    let live: [ActiveJob] = (1...5).map {
      ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
    }
    let display = PollResultBuilder.buildJobDisplay(live: live, cache: [:])
    #expect(display.count == 5, "jobCacheLimit must not truncate live jobs")
  }

  /// Verifies that `buildJobDisplay` caps the total displayed jobs at `jobDisplayLimit` when live + cached entries exceed it.
  @Test func buildJobDisplayCapsAtJobDisplayLimit() {
    let live: [ActiveJob] = (1...8).map {
      ActiveJob(id: $0, name: "Job \($0)", status: "in_progress")
    }
    let cached: [Int: ActiveJob] = Dictionary(
      uniqueKeysWithValues: (100...106).map {
        (
          $0,
          ActiveJob(
            id: $0, name: "Done \($0)", status: "completed",
            conclusion: "success",
            completedAt: Date(timeIntervalSinceReferenceDate: Double($0)))
        )
      })
    let display = PollResultBuilder.buildJobDisplay(live: live, cache: cached)
    #expect(display.count <= PollResultBuilder.jobDisplayLimit)
  }

  // MARK: applyVanishedJobs

  /// Vanished jobs fall back to `.neutral` (not `.cancelled`) because `.cancelled` is the
  /// conclusion GitHub assigns when a user explicitly cancels via the UI. A job that silently
  /// disappears from the feed never received that API update, so using `.neutral` avoids
  /// misattributing the cause.
  @Test func applyVanishedJobsMovesVanishedJobToCache() {
    let vanished = ActiveJob(id: 55, name: "Vanished", status: "in_progress")
    var cache: [Int: ActiveJob] = [:]
    PollResultBuilder.applyVanishedJobs(
      snapPrev: [55: vanished],
      liveIDs: [],
      now: Date(),
      into: &cache
    )
    #expect(cache[55] != nil)
    #expect(cache[55]?.jobStatus == .completed)
    #expect(cache[55]?.isDimmed == true)
    #expect(
      cache[55]?.jobConclusion == .neutral,
      "Missing conclusion defaults to neutral")
  }

  /// Verifies that `applyVanishedJobs` does not overwrite a cache entry that already exists for the same job ID.
  @Test func applyVanishedJobsDoesNotOverwriteExistingCacheEntry() {
    let vanished = ActiveJob(id: 55, name: "Vanished", status: "in_progress")
    let existing = ActiveJob(
      id: 55, name: "Vanished", status: "completed",
      conclusion: "failure", isDimmed: true)
    var cache: [Int: ActiveJob] = [55: existing]
    PollResultBuilder.applyVanishedJobs(
      snapPrev: [55: vanished],
      liveIDs: [],
      now: Date(),
      into: &cache
    )
    #expect(cache[55]?.jobConclusion == .failure, "Existing cache entry must not be overwritten")
  }

  /// Verifies that `applyVanishedJobs` does not add a job to the cache when that job is still present in the live feed.
  @Test func applyVanishedJobsIgnoresStillLiveJobs() {
    let job = ActiveJob(id: 77, name: "StillLive", status: "in_progress")
    var cache: [Int: ActiveJob] = [:]
    PollResultBuilder.applyVanishedJobs(
      snapPrev: [77: job],
      liveIDs: [77],
      now: Date(),
      into: &cache
    )
    #expect(cache[77] == nil)
  }

  /// Verifies that `applyVanishedJobs` preserves an already-set conclusion on the vanished job rather than overwriting it with `.neutral`.
  @Test func applyVanishedJobsPreservesExistingConclusion() {
    let vanished = ActiveJob(
      id: 88, name: "Done", status: "completed",
      conclusion: "failure")
    var cache: [Int: ActiveJob] = [:]
    PollResultBuilder.applyVanishedJobs(
      snapPrev: [88: vanished],
      liveIDs: [],
      now: Date(),
      into: &cache
    )
    #expect(cache[88]?.jobConclusion == .failure)
  }

  // MARK: buildJobState

  /// Verifies that a live in-progress job fetched by `buildJobState` appears in the `display` array.
  @Test func buildJobStateLiveJobAppearsInDisplay() async {
    let liveJob = ActiveJob(id: 99, name: "CI", status: "in_progress")
    let result = await PollResultBuilder.buildJobState(
      snapPrev: [:],
      snapCache: [:],
      fetchJobs: { [liveJob] },
      backfill: { _ in }
    )
    #expect(result.display.contains(where: { $0.id == 99 }))
  }

  /// Verifies that a completed job returned by `fetchJobs` is moved into `newCache` with `isDimmed == true`.
  @Test func buildJobStateCompletedJobMovesToCache() async {
    let doneJob = ActiveJob(id: 42, name: "Deploy", status: "completed", conclusion: "success")
    let result = await PollResultBuilder.buildJobState(
      snapPrev: [:],
      snapCache: [:],
      fetchJobs: { [doneJob] },
      backfill: { _ in }
    )
    #expect(result.newCache.keys.contains(42))
    #expect(result.newCache[42]?.isDimmed == true)
  }

  /// Verifies that a previously live job absent from the current fetch is treated as vanished and appears in `newCache` as completed.
  @Test func buildJobStateVanishedLiveJobAppearsInCache() async {
    let prev = ActiveJob(id: 11, name: "Old", status: "in_progress")
    let result = await PollResultBuilder.buildJobState(
      snapPrev: [11: prev],
      snapCache: [:],
      fetchJobs: { [] },
      backfill: { _ in }
    )
    #expect(result.newCache[11] != nil)
    #expect(result.newCache[11]?.jobStatus == .completed)
  }

}

// MARK: - JobStatus.isActive

@Suite("JobStatus.isActive")
struct JobStatusIsActiveTests {

  @Test
  func activeClassification() {
    let cases: [(status: JobStatus, expected: Bool)] = [
      (.queued,              true),
      (.inProgress,          true),
      (.waiting,             true),
      (.requested,           true),
      (.pending,             true),
      (.completed,           false),
      (.unknown("draining"), false),
    ]
    for testCase in cases {
      #expect(
        testCase.status.isActive == testCase.expected,
        "status=\(testCase.status) expected isActive=\(testCase.expected)"
      )
    }
  }
}

// MARK: - JobConclusion.isFailure

@Suite("JobConclusion.isFailure")
struct JobConclusionIsFailureTests {

  /// Verifies that `.failure`, `.timedOut`, `.startupFailure`, and `.actionRequired` all return `true` for `isFailure`.
  @Test(arguments: [
    JobConclusion.failure,
    .timedOut,
    .startupFailure,
    .actionRequired,
  ])
  func isFailureTrue(conclusion: JobConclusion) {
    #expect(conclusion.isFailure)
  }

  /// Verifies that `.success`, `.neutral`, `.stale`, `.cancelled`, `.skipped`, and unknown conclusions return `false` for `isFailure`.
  @Test(arguments: [
    JobConclusion.success,
    .neutral,
    .stale,
    .cancelled,
    .skipped,
    .unknown("neutral_extended"),
  ])
  func isFailureFalse(conclusion: JobConclusion) {
    #expect(!conclusion.isFailure)
  }
}

// MARK: - PollResultBuilder.buildGroupState (fix #1041)

@Suite("PollResultBuilder.buildGroupState")
struct PollResultBuilderGroupStateTests {

  private func makeGroup(
    id runID: Int,
    sha: String,
    groupStatus: GroupStatus = .completed,
    conclusion: String = "failure",
    jobStatus: JobStatus? = nil,
    isDimmed: Bool = false
  ) -> WorkflowActionGroup {
    let resolvedJobStatus: JobStatus =
      jobStatus
      ?? {
        switch groupStatus {
        case .inProgress: return .inProgress
        case .loading: return .queued
        case .queued: return .queued
        case .completed: return .completed
        }
      }()
    let jobConclusion: JobConclusion? =
      resolvedJobStatus == .completed
      ? JobConclusion(rawString: conclusion)
      : nil
    let job = ActiveJob(
      id: runID * 10,
      name: "job",
      status: resolvedJobStatus,
      conclusion: jobConclusion
    )
    let runConclusion: JobConclusion? =
      resolvedJobStatus == .completed
      ? JobConclusion(rawString: conclusion)
      : nil
    return WorkflowActionGroup(
      headSha: sha,
      label: String(sha.prefix(7)),
      title: "commit message",
      headBranch: "main",
      repo: "owner/repo",
      runs: [
        WorkflowRunRef(
          id: runID, name: "CI", status: resolvedJobStatus, conclusion: runConclusion, htmlUrl: nil)
      ],
      jobs: [job],
      firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
      lastJobCompletedAt: resolvedJobStatus == .completed
        ? Date(timeIntervalSinceReferenceDate: 60) : nil,
      isDimmed: isDimmed
    )
  }

  /// Verifies that a fully completed group is routed to the cache and does not appear as a live (non-dimmed) display row.
  @Test func completedOnlyGroupIsRoutedToCacheNotLive() async {
    let completedGroup = makeGroup(
      id: 500, sha: "aabbcc", groupStatus: .completed, conclusion: "failure")
    let result = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      fetchGroups: { _ in [completedGroup] },
      enrichJobs: { $0 }
    )
    #expect(
      !result.display.contains { !$0.isDimmed },
      "Completed group must not appear as a live (non-dimmed) row")
    #expect(!result.newGroupCache.isEmpty)
  }

  /// Verifies that an in-progress group appears as a live (non-dimmed) row in the display array.
  @Test func inProgressGroupAppearsLiveInDisplay() async {
    let liveGroup = makeGroup(
      id: 600, sha: "ddeeff", groupStatus: .inProgress, jobStatus: .inProgress)
    let result = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      fetchGroups: { _ in [liveGroup] },
      enrichJobs: { $0 }
    )
    #expect(result.display.contains(where: { !$0.isDimmed }))
  }

  /// Verifies that a previously live group transitions cleanly to cache once it completes, leaving no live (non-dimmed) rows.
  @Test func previouslyLiveGroupSelfHealsAfterCompletion() async {
    let sha = "cafe01"
    let liveGroup = makeGroup(id: 901, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
    let completedGroup = makeGroup(
      id: 901, sha: sha, groupStatus: .completed, conclusion: "failure")
    let result = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [liveGroup.id: liveGroup],
      snapGroupCache: [:],
      fetchGroups: { _ in [completedGroup] },
      enrichJobs: { $0 }
    )
    #expect(!result.display.contains { !$0.isDimmed })
    #expect(result.newGroupCache[completedGroup.id] != nil)
  }

  /// Verifies that a SHA with both live and completed runs produces exactly one display entry and nothing in the group cache.
  @Test func shaWithBothLiveAndCompletedRunsProducesOneDisplayEntry() async {
    let sha = "beef02"
    let mixedGroup = WorkflowActionGroup(
      headSha: sha,
      label: String(sha.prefix(7)),
      title: "mixed commit",
      headBranch: "main",
      repo: "owner/repo",
      runs: [
        WorkflowRunRef(
          id: 902, name: "Lint", status: JobStatus.inProgress, conclusion: nil, htmlUrl: nil),
        WorkflowRunRef(
          id: 903, name: "Deploy", status: JobStatus.completed, conclusion: JobConclusion.success,
          htmlUrl: nil),
      ],
      jobs: [
        ActiveJob(id: 9020, name: "lint-job", status: JobStatus.inProgress),
        ActiveJob(
          id: 9030, name: "deploy-job", status: JobStatus.completed,
          conclusion: JobConclusion.success),
      ],
      firstJobStartedAt: Date(timeIntervalSinceReferenceDate: 0),
      lastJobCompletedAt: nil,
      isDimmed: false
    )
    let result = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      fetchGroups: { _ in [mixedGroup] },
      enrichJobs: { $0 }
    )
    let displayForSha = result.display.filter { $0.headSha == sha }
    let cacheForSha = result.newGroupCache.values.filter { $0.headSha == sha }
    #expect(displayForSha.count == 1)
    #expect(cacheForSha.isEmpty)
  }

}

// MARK: - PollResultBuilder.evictFreshShas (#2444)

@Suite("PollResultBuilder.evictFreshShas")
struct PollResultBuilderEvictionTests {

  /// Builds a minimal `WorkflowActionGroup` for eviction tests.
  ///
  /// `id` is used as the dictionary key in the ID-keyed cache (mirroring
  /// `snapGroupCache` in `buildGroupState`). `event` sets `normalizedEvent`
  /// so the value-based composite reconstruction in `evictFreshShas` produces
  /// the expected `"headSha:normalizedEvent"` string.
  private func makeGroup(sha: String, event: String, id: String) -> WorkflowActionGroup {
    WorkflowActionGroup(
      headSha: sha, label: sha, title: "commit", headBranch: nil,
      repo: "owner/repo", runs: [], jobs: [],
      firstJobStartedAt: nil, lastJobCompletedAt: nil, createdAt: nil,
      normalizedEvent: event
    )
  }

  /// Verifies that a fresh `push` (`"commit"`) group does NOT evict a cached
  /// `workflow_dispatch` group sharing the same SHA — regression guard for #2444.
  ///
  /// Before #2444, `evictFreshShas` evicted by bare `headSha`, so a live `push`
  /// run would ghost-evict an unrelated `workflow_dispatch` cache entry on the
  /// same commit.
  @Test func evictFreshShasDoesNotEvictDifferentEventOnSameSha() {
    let sha = "sharedsha"
    let dispatchGroup = makeGroup(sha: sha, event: "workflow_dispatch", id: "id-dispatch")
    let pushGroup     = makeGroup(sha: sha, event: "commit",            id: "id-push")
    // ID-keyed cache — mirrors snapGroupCache in buildGroupState.
    let cache: [String: WorkflowActionGroup] = [
      "id-dispatch": dispatchGroup,
      "id-push":     pushGroup,
    ]
    // Only the push/commit group is fresh this cycle.
    let fresh = [makeGroup(sha: sha, event: "commit", id: "id-push-new")]
    let result = PollResultBuilder.evictFreshShas(from: cache, freshGroups: fresh)
    // The commit entry must be evicted; the dispatch entry must survive.
    #expect(result["id-push"] == nil,     "fresh push group must be evicted")
    #expect(result["id-dispatch"] != nil, "dispatch group on same SHA must NOT be evicted")
  }

  /// Verifies that a fresh group evicts all cached entries sharing the same
  /// composite identity (`headSha:normalizedEvent`), including stale entries
  /// from a previous run on the same SHA+event.
  @Test func evictFreshShasEvictsSameCompositeKey() {
    let sha = "evictme"
    let stale = makeGroup(sha: sha, event: "commit", id: "id-stale")
    let cache: [String: WorkflowActionGroup] = ["id-stale": stale]
    let fresh = [makeGroup(sha: sha, event: "commit", id: "id-fresh")]
    let result = PollResultBuilder.evictFreshShas(from: cache, freshGroups: fresh)
    #expect(result.isEmpty, "stale entry for same SHA+event must be evicted")
  }

  /// Verifies that a completely unrelated SHA is never evicted, even when multiple
  /// fresh groups are present.
  @Test func evictFreshShasPreservesUnrelatedSha() {
    let keepGroup  = makeGroup(sha: "keepme",  event: "commit", id: "id-keep")
    let freshGroup = makeGroup(sha: "freshsha", event: "commit", id: "id-fresh")
    let cache: [String: WorkflowActionGroup] = ["id-keep": keepGroup]
    let result = PollResultBuilder.evictFreshShas(from: cache, freshGroups: [freshGroup])
    #expect(result["id-keep"] != nil, "unrelated SHA must not be evicted")
  }

  /// Verifies via `buildGroupState` that a cached `workflow_dispatch` group survives
  /// when only a fresh `push`/`commit` group is returned for the same SHA.
  ///
  /// This is the correct-layer regression guard for #2444: `evictFreshShas` is called
  /// inside `buildGroupState`, not inside `WorkflowActionGroupFetcher.fetch`.
  @Test func buildGroupStateDoesNotEvictDispatchCacheEntryWhenFreshCommitArrives() async {
    let sha = "sharedsha"
    // normalizedEvent must be "workflow_dispatch" so evictFreshShas distinguishes
    // this entry from the fresh commit group arriving on the same SHA.
    let dispatchGroup = makeGroup(sha: sha, event: "workflow_dispatch", id: "id-dispatch")
    let dispatchDimmed = dispatchGroup.copying(isDimmed: true)
    // Fresh fetch returns only a commit group on the same SHA.
    let freshCommit = makeGroup(sha: sha, event: "commit", id: "id-commit-new")
    let result = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: ["id-dispatch": dispatchDimmed],
      fetchGroups: { _ in [freshCommit] },
      enrichJobs: { $0 }
    )
    let dispatchSurvives = result.newGroupCache.values.contains { group in
      group.headSha == sha && group.normalizedEvent == "workflow_dispatch"
    }
    #expect(
      dispatchSurvives,
      "workflow_dispatch cache entry must not be evicted by a fresh commit group on the same SHA")
  }

}

// MARK: - ProcessRunner.runAsync stdin

@Suite("ProcessRunner.runAsync stdin")
struct ProcessRunnerRunAsyncStdinTests {

  @Test(.timeLimit(.minutes(1)))
  func runAsyncStdinSmallPayloadRoundtrip() async {
    let input = "hello stdin"
    let data = Data(input.utf8)
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      stdin: data
    )
    #expect(result.exitCode == 0)
    #expect(result.output == input)
  }

  @Test(.timeLimit(.minutes(1)))
  func runAsyncStdinLargePayloadRoundtrip() async {
    let input = String(repeating: "x", count: 1_024 * 1_024)
    let data = Data(input.utf8)
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/cat"),
      arguments: [],
      stdin: data
    )
    #expect(result.exitCode == 0)
    #expect(result.output.count == input.count)
  }

  @Test(.timeLimit(.minutes(1)))
  func runAsyncNonZeroExitCode() async {
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      arguments: [],
      stdin: nil
    )
    #expect(result.exitCode == 1)
  }

  /// #1983 Step 5 — A process that writes to stderr must complete normally.
  /// The exit code must reflect the process result (non-zero here) and the
  /// runner must not hang waiting for stderr to drain.
  ///
  /// ProcessRunner discards stderr — it is not captured or exposed to callers.
  /// This satisfies the audit requirement to either assert stderr content or
  /// explicitly document that it is not captured.
  @Test(.timeLimit(.minutes(1)))
  func runAsyncStderrDoesNotHang() async {
    // /bin/sh writes "err" to stderr then exits 1.
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "echo err >&2; exit 1"],
      stdin: nil
    )
    #expect(result.exitCode == 1, "process exit code must be 1")
    // stdout must be empty — the message went to stderr, not stdout.
    // ProcessRunner discards stderr; only stdout is returned in result.output.
    #expect(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "stdout must be empty when output is written only to stderr")
  }

}

