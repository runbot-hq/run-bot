// RunBotCoreTests.swift
// RunBotCoreTests
import Collections
import Foundation
import GitHubClient
import RunBotCore
import Testing

// MARK: - ActiveJob.elapsed

@Suite("ActiveJob.elapsed")
struct ActiveJobElapsedTests {

  /// A queued job (never started) returns "00:00" elapsed time.
  @Test func elapsedQueuedReturnsZero() {
    let job = ActiveJob(id: 1, name: "J", status: "queued")
    #expect(job.elapsed == "00:00")
  }

  /// Elapsed time is formatted as "MM:SS" when start and end dates are provided for a completed job.
  @Test func elapsedCompletedWithTimes() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = Date(timeIntervalSinceReferenceDate: 125)
    let job = ActiveJob(
      id: 1, name: "J", status: "completed",
      conclusion: "success",
      startedAt: start,
      completedAt: end
    )
    #expect(job.elapsed == "02:05")
  }

  /// A completed job without timestamps returns "--:--" as elapsed time.
  @Test func elapsedCompletedMissingTimesReturnsDashes() {
    let job = ActiveJob(id: 1, name: "J", status: "completed", conclusion: "success")
    #expect(job.elapsed == "--:--")
  }

  /// An in-progress job calculates elapsed time from startedAt to now, within a reasonable tolerance.
  @Test func elapsedInProgressUsesStartedAt() {
    let start = Date(timeIntervalSinceNow: -90)
    let job = ActiveJob(id: 1, name: "J", status: "in_progress", startedAt: start)
    let mins = Int(job.elapsed.prefix(2))!
    let secs = Int(job.elapsed.suffix(2))!
    let total = mins * 60 + secs
    #expect(total >= 89)
    #expect(total <= 95)
  }

  /// An in-progress job falls back to createdAt when startedAt is nil (still queued/assigning).
  @Test func elapsedInProgressFallsBackToCreatedAt() {
    let created = Date(timeIntervalSinceNow: -60)
    let job = ActiveJob(id: 1, name: "J", status: "in_progress", createdAt: created)
    let mins = Int(job.elapsed.prefix(2))!
    let secs = Int(job.elapsed.suffix(2))!
    let total = mins * 60 + secs
    #expect(total >= 59)
    #expect(total <= 65)
  }

  /// An in-progress job with neither startedAt nor createdAt returns "00:00".
  @Test func elapsedInProgressNeitherDateReturnsZero() {
    let job = ActiveJob(id: 1, name: "J", status: "in_progress")
    #expect(job.elapsed == "00:00")
  }
}

// MARK: - JobStep.elapsed

@Suite("JobStep.elapsed")
struct JobStepElapsedTests {

  /// A completed job step formats elapsed time as "MM:SS" given fixed start/end dates.
  @Test func elapsedFixedDuration() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = Date(timeIntervalSinceReferenceDate: 185)  // 3m 5s
    let step = JobStep(
      id: 1, name: "S", status: "completed",
      startedAt: start, completedAt: end)
    #expect(step.elapsed == "03:05")
  }

  /// A step with nil start and end dates returns "00:00".
  @Test func elapsedNilDatesReturnsZero() {
    let step = JobStep(id: 1, name: "S", status: "in_progress")
    #expect(step.elapsed == "00:00")
  }

  /// Exactly one minute (60 seconds) is formatted as "01:00".
  @Test func elapsedExactlyOneMinute() {
    let start = Date(timeIntervalSinceReferenceDate: 0)
    let end = Date(timeIntervalSinceReferenceDate: 60)
    let step = JobStep(
      id: 1, name: "S", status: "completed",
      startedAt: start, completedAt: end)
    #expect(step.elapsed == "01:00")
  }
}

// MARK: - ActiveJob.isLocalRunner

@Suite("ActiveJob.isLocalRunner")
struct ActiveJobIsLocalRunnerTests {

  /// isLocalRunner returns nil when a job has no runner name.
  @Test func isLocalRunnerNilWhenNoRunnerName() {
    let job = ActiveJob(id: 1, name: "J", status: "queued")
    #expect(job.isLocalRunner == nil)
  }

  /// All known hosted-runner name patterns return false — they are not local runners.
  @Test(arguments: [
    "ubuntu-latest",
    "macos-14",
    "windows-2022",
    "buildjet-4vcpu-ubuntu-2204",
    "depot-ubuntu-22.04",
    "GitHub Actions 12",
  ])
  func isLocalRunnerFalseForHostedRunners(runnerName: String) {
    let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: runnerName)
    #expect(job.isLocalRunner == false)
  }

  /// An arbitrary self-hosted runner name is identified as local.
  @Test func isLocalRunnerTrueForSelfHosted() {
    let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "my-mac-mini")
    #expect(job.isLocalRunner == true)
  }

  /// A custom-named runner (e.g., "office-m2-runner") is identified as local.
  @Test func isLocalRunnerTrueForCustomName() {
    let job = ActiveJob(id: 1, name: "J", status: "completed", runnerName: "office-m2-runner")
    #expect(job.isLocalRunner == true)
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

  /// Verifies that `trimJobCache` evicts the oldest (lowest `completedAt`) entry when the cache exceeds the limit.
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
  /// misattributing the cause and avoids triggering isHookConclusion side-effects.
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
    #expect(cache[55]?.status == "completed")
    #expect(cache[55]?.isDimmed == true)
    #expect(
      cache[55]?.conclusion == "neutral",
      "Missing conclusion defaults to neutral (.cancelled has isHookConclusion side-effects)")
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
    #expect(cache[55]?.conclusion == "failure", "Existing cache entry must not be overwritten")
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

  /// Verifies that `applyVanishedJobs` preserves an already-set conclusion on the vanished job rather than overwriting it with `"neutral"`.
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
    #expect(cache[88]?.conclusion == "failure")
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
    #expect(result.newCache[11]?.status == "completed")
  }

  // MARK: trimSeenGroupIDs

  /// Verifies that `trimSeenGroupIDs` is a no-op when the set is exactly at the limit.
  @Test func trimSeenGroupIDsNoopAtLimit() {
    var ids: OrderedSet<String> = OrderedSet((1...10).map { "group-\($0)" })
    PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
    #expect(ids.count == 10)
  }

  /// Verifies that `trimSeenGroupIDs` trims to exactly the limit (not to limit/2) when one entry over.
  @Test func trimSeenGroupIDsTrimsToLimitNotHalf() {
    let limit = 10
    var ids: OrderedSet<String> = OrderedSet((1...(limit + 1)).map { "group-\($0)" })
    PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
    #expect(ids.count == limit)
  }

  /// Verifies that `trimSeenGroupIDs` correctly trims a set that is well over the limit down to exactly the limit.
  @Test func trimSeenGroupIDsWellOverLimit() {
    let limit = 10
    var ids: OrderedSet<String> = OrderedSet((1...25).map { "group-\($0)" })
    PollResultBuilder.trimSeenGroupIDs(&ids, limit: limit)
    #expect(ids.count == limit)
  }

  /// Oldest entries (lowest indices) must be evicted first — FIFO.
  @Test func trimSeenGroupIDsEvictsOldestFirst() {
    var ids: OrderedSet<String> = OrderedSet((1...12).map { "group-\($0)" })
    PollResultBuilder.trimSeenGroupIDs(&ids, limit: 10)
    #expect(ids.count == 10)
    #expect(!ids.contains("group-1"))
    #expect(!ids.contains("group-2"))
    #expect(ids.first == "group-3")
    #expect(ids.last == "group-12")
  }
}

// MARK: - JobStatus.isActive

@Suite("JobStatus.isActive")
struct JobStatusIsActiveTests {

  /// Verifies that queued, in-progress, waiting, requested, and pending statuses are active, while completed and unknown are not.
  @Test func activeStatuses() {
    #expect(JobStatus.queued.isActive)
    #expect(JobStatus.inProgress.isActive)
    #expect(JobStatus.waiting.isActive)
    #expect(JobStatus.requested.isActive)
    #expect(JobStatus.pending.isActive)
    #expect(!JobStatus.completed.isActive)
    #expect(!JobStatus.unknown("draining").isActive)
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

// MARK: - JobConclusion.isHookConclusion

@Suite("JobConclusion.isHookConclusion")
struct JobConclusionIsHookConclusionTests {

  /// Verifies that `.failure`, `.timedOut`, `.startupFailure`, `.actionRequired`, and `.cancelled` all return `true` for `isHookConclusion`.
  @Test(arguments: [
    JobConclusion.failure,
    .timedOut,
    .startupFailure,
    .actionRequired,
    .cancelled,
  ])
  func isHookConclusionTrue(conclusion: JobConclusion) {
    #expect(conclusion.isHookConclusion)
  }

  /// Verifies that `.cancelled` is a hook conclusion but not a failure — it must not trigger isFailure side-effects.
  @Test func cancelledIsHookConclusionButNotFailure() {
    #expect(JobConclusion.cancelled.isHookConclusion)
    #expect(!JobConclusion.cancelled.isFailure)
  }

  /// Verifies that `.success`, `.skipped`, `.neutral`, `.stale`, and unknown conclusions return `false` for `isHookConclusion`.
  @Test(arguments: [
    JobConclusion.success,
    .skipped,
    .neutral,
    .stale,
    .unknown("some_future_value"),
  ])
  func isHookConclusionFalse(conclusion: JobConclusion) {
    #expect(!conclusion.isHookConclusion)
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
      deps: GroupStateDeps(
        fetchGroups: { _ in [completedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in },
        enrichJobs: { $0 }
      )
    )
    #expect(
      result.display.filter { !$0.isDimmed }.isEmpty,
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
      deps: GroupStateDeps(
        fetchGroups: { _ in [liveGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in },
        enrichJobs: { $0 }
      )
    )
    #expect(result.display.contains(where: { !$0.isDimmed }))
  }

  /// Verifies that `fireFailureHook` is called exactly once for a new failed group that has not been seen before.
  @Test func fireFailureHookCalledOnceForNewFailedGroup() async {
    let failedGroup = makeGroup(
      id: 700, sha: "112233", groupStatus: .completed, conclusion: "failure")
    let counter = HookCounter()
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [failedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      )
    )
    #expect(
      await counter.value == 1, "fireFailureHook must fire exactly once for a new failed group")
  }

  /// Verifies that `fireFailureHook` is not called when a completed group has a successful conclusion.
  @Test func fireFailureHookNotCalledForSuccessGroup() async {
    let successGroup = makeGroup(
      id: 750, sha: "aabbdd", groupStatus: .completed, conclusion: "success")
    let counter = HookCounter()
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [successGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      )
    )
    #expect(await counter.value == 0)
  }

  /// Verifies that `fireFailureHook` is not called for a group whose ID is already present in `snapSeenGroupIDs`, even if the group cache has been evicted.
  @Test func fireFailureHookNotCalledWhenGroupAlreadySeenEvenIfEvictedFromCache() async {
    let completedGroup = makeGroup(
      id: 800, sha: "445566", groupStatus: .completed, conclusion: "failure", isDimmed: true)
    let counter = HookCounter()
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [completedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      ),
      snapSeenGroupIDs: [completedGroup.id]
    )
    #expect(await counter.value == 0)
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
      deps: GroupStateDeps(
        fetchGroups: { _ in [completedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in },
        enrichJobs: { $0 }
      )
    )
    #expect(result.display.filter { !$0.isDimmed }.isEmpty)
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
      deps: GroupStateDeps(
        fetchGroups: { _ in [mixedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in },
        enrichJobs: { $0 }
      )
    )
    let displayForSha = result.display.filter { $0.headSha == sha }
    let cacheForSha = result.newGroupCache.values.filter { $0.headSha == sha }
    #expect(displayForSha.count == 1)
    #expect(cacheForSha.count == 0)
  }

  /// Regression: a group ID that has been FIFO-evicted from seenGroupIDs must re-fire
  /// the hook when it next appears — this is the documented known limitation (bounded
  /// memory; occasional re-fire is an accepted trade-off).
  ///
  /// Scenario:
  /// 1. Poll 1 — group fires hook; ID lands at index 0 of seenGroupIDs (oldest).
  /// 2. Synthetic eviction — fill seenGroupIDs to seenGroupIDsLimit with filler IDs
  ///    (real ID remains at index 0), then trim by 1 to evict it via FIFO.
  /// 3. Poll 2 — ID is gone from seenGroupIDs; hook re-fires (counter reaches 2).
  @Test func evictedGroupIDRefiresHookOnNextPoll() async {
    let failedGroup = makeGroup(
      id: 1001, sha: "dead01", groupStatus: .completed, conclusion: "failure")
    let counter = HookCounter()

    // Poll 1: hook fires for the first time; ID is registered in newSeenGroupIDs.
    let poll1 = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [failedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      )
    )
    #expect(await counter.value == 1, "hook must fire once on first poll")
    #expect(poll1.newSeenGroupIDs.contains(failedGroup.id))

    // Synthetic FIFO eviction:
    // Place the real group ID at index 0 (oldest), then fill to seenGroupIDsLimit
    // with filler IDs. Trim by 1 — trimSeenGroupIDs removes the single oldest entry,
    // which is the real group ID, because OrderedSet preserves insertion order.
    var seenAfterEviction: OrderedSet<String> = [failedGroup.id]
    for i in 0..<(PollResultBuilder.seenGroupIDsLimit - 1) {
      seenAfterEviction.append("filler-\(i)")
    }
    #expect(seenAfterEviction.count == PollResultBuilder.seenGroupIDsLimit)
    PollResultBuilder.trimSeenGroupIDs(
      &seenAfterEviction, limit: PollResultBuilder.seenGroupIDsLimit - 1)
    #expect(
      !seenAfterEviction.contains(failedGroup.id),
      "real group ID must be evicted (it was the oldest entry)")

    // Poll 2: ID is no longer in seenGroupIDs — hook must re-fire.
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [:],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [failedGroup] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      ),
      snapSeenGroupIDs: seenAfterEviction
    )
    #expect(await counter.value == 2, "hook must re-fire after FIFO eviction from seenGroupIDs")
  }

  /// Verifies that `doneGroups` are registered in `seenGroupIDs` before `freezeVanishedGroups` runs, preventing a double hook fire when a group transitions live → completed in the same poll.
  @Test func doneGroupsSeenBeforeFreezeVanishedGroupsPreventsDoubleFire() async {
    let sha = "ff0011"
    let liveVersion = makeGroup(
      id: 1002, sha: sha, groupStatus: .inProgress, jobStatus: .inProgress)
    let completedVersion = makeGroup(
      id: 1002, sha: sha, groupStatus: .completed, conclusion: "failure")
    let counter = HookCounter()
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [liveVersion.id: liveVersion],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [completedVersion] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      )
    )
    #expect(
      await counter.value == 1,
      "doneGroups must be marked seen before freezeVanishedGroups runs to prevent double-fire")
  }

  /// Regression: a group that fires the hook via the vanish path (freezeVanishedGroups)
  /// must NOT re-fire if its cache entry is later evicted by trimGroupCache and it
  /// reappears in snapPrevGroups on a subsequent poll. seenGroupIDs must survive
  /// cache eviction because it is trimmed independently (seenGroupIDsLimit >> groupCacheLimit).
  ///
  /// The vanished group must carry a hook-triggering conclusion on its runs for the
  /// hook to fire at all — freezeVanishedGroups checks `run.conclusion?.isHookConclusion`.
  /// Here we use a completed run with `conclusion: .failure` to exercise the full path.
  @Test func vanishPathHookDoesNotRefireAfterCacheEviction() async {
    let sha = "cc0011"
    // Build a group whose run already has a failure conclusion — this is what
    // freezeVanishedGroups checks via `run.conclusion?.isHookConclusion == true`.
    // An in-progress run has conclusion == nil, so the hook would never fire;
    // we need a completed run conclusion to trigger the vanish-path hook.
    let vanishedGroup = makeGroup(
      id: 1003, sha: sha, groupStatus: .completed, conclusion: "failure", isDimmed: false)

    // Poll 1: group is in snapPrevGroups but absent from fetchGroups — vanish path fires the hook.
    // Note: fetchGroups returns [] so the group goes through freezeVanishedGroups, not doneGroups.
    let counter = HookCounter()
    let poll1 = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [vanishedGroup.id: vanishedGroup],
      snapGroupCache: [:],
      deps: GroupStateDeps(
        fetchGroups: { _ in [] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      )
    )
    #expect(await counter.value == 1, "hook must fire on first vanish")
    #expect(
      poll1.newSeenGroupIDs.contains(vanishedGroup.id), "vanish path must insert into seenGroupIDs")

    // Simulate cache eviction: poll1's group cache is trimmed to 0 (groupCacheLimit=0).
    // seenGroupIDs survives because it is passed forward independently.
    var evictedCache = poll1.newGroupCache
    PollResultBuilder.trimGroupCache(&evictedCache, limit: 0)
    #expect(evictedCache.isEmpty, "cache must be empty after eviction")

    // Poll 2: same group reappears in snapPrevGroups (e.g. from stale store state),
    // cache is empty, but seenGroupIDs still contains the ID — hook must NOT re-fire.
    _ = await PollResultBuilder.buildGroupState(
      snapPrevGroups: [vanishedGroup.id: vanishedGroup],
      snapGroupCache: evictedCache,
      deps: GroupStateDeps(
        fetchGroups: { _ in [] },
        scopeFromGroup: { $0.repo },
        fireFailureHook: { _, _ in await counter.increment() },
        enrichJobs: { $0 }
      ),
      snapSeenGroupIDs: poll1.newSeenGroupIDs
    )
    #expect(
      await counter.value == 1,
      "hook must not re-fire after cache eviction when seenGroupIDs still holds the ID")
  }
}

// MARK: - ProcessRunner.runAsync stdin

@Suite("ProcessRunner.runAsync stdin")
struct ProcessRunnerRunAsyncStdinTests {

  /// Verifies that a small payload piped through `/bin/cat` via `runAsync` stdin is returned intact with exit code 0.
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

  /// Verifies that a 1 MiB payload piped through `/bin/cat` via `runAsync` stdin is returned with the same byte count and exit code 0.
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

  // MARK: - Exit codes

  /// A command that exits with a non-zero status must report that exit code.
  /// Regression guard: a bug that always reports exitCode == 0 would silently pass
  /// the stdin round-trip tests above while breaking callers that rely on exit codes.
  /// `/usr/bin/false` always exits 1 on macOS and Linux — asserting == 1 is deterministic.
  @Test(.timeLimit(.minutes(1)))
  func runAsyncNonZeroExitCode() async {
    let result = await ProcessRunner.runAsync(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      arguments: [],
      stdin: nil
    )
    #expect(result.exitCode == 1)
  }
}

// MARK: - RunnerConfigStoreError.errorDescription

@Suite("RunnerConfigStoreError.errorDescription")
struct RunnerConfigStoreErrorDescriptionTests {

  /// .malformedExistingFile errorDescription must contain the install path,
  /// the word "malformed", and the phrase "agent-managed" so callers and UI
  /// can identify both the file location and the consequence.
  @Test func malformedExistingFileDescriptionContainsPathAndConsequence() {
    let error = RunnerConfigStoreError.malformedExistingFile("/opt/runners/my-runner")
    let desc = error.errorDescription ?? ""
    #expect(desc.contains("/opt/runners/my-runner"))
    #expect(desc.contains("malformed"))
    #expect(desc.contains("agent-managed"))
  }

  /// .malformedExistingFile must be distinct from .decodeFailed — the two cases
  /// describe different failure sites (save pre-read vs. load) and must not
  /// share an identical description.
  @Test func malformedExistingFileDescriptionDiffersFromDecodeFailed() {
    let malformed = RunnerConfigStoreError.malformedExistingFile("/opt/runners/r")
    let decode = RunnerConfigStoreError.decodeFailed("/opt/runners/r")
    #expect(malformed.errorDescription != decode.errorDescription)
  }
}
