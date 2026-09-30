// RunnerModelContractTests.swift
// RunBotCoreTests
import Foundation
import GitHubClient
import Testing
@testable import RunBotCore

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

// MARK: - RunnerModel presentation

/// One state-policy matrix for ``RunnerModel``'s twin projections of the same
/// internal resolved state: `displayStatus` (text) and `statusColor` (colour).
/// Asserting both in every fixture keeps them from drifting apart.
@Suite("RunnerModel presentation")
struct RunnerModelPresentationTests {

  @Test
  func presentationFollowsResolvedState() {
    struct Case {
      let label: String
      let isRunning: Bool
      let githubStatus: RunnerStatus?
      let isBusy: Bool
      let warning: String?
      let expectedText: String
      let expectedColor: RunnerModel.StatusColor
    }

    let cases: [Case] = [
      // Lifecycle warning outranks running/busy for both text and colour.
      Case(label: "warning wins",
           isRunning: true, githubStatus: .online, isBusy: true,
           warning: "update required",
           expectedText: "update required", expectedColor: .offline),
      // Local process up + executing a job.
      Case(label: "local busy",
           isRunning: true, githubStatus: nil, isBusy: true,
           warning: nil,
           expectedText: "busy", expectedColor: .busy),
      // GitHub reports busy even though the local process is absent.
      Case(label: "remote busy",
           isRunning: false, githubStatus: .busy, isBusy: false,
           warning: nil,
           expectedText: "busy", expectedColor: .busy),
      // Local process up, no job.
      Case(label: "local process running",
           isRunning: true, githubStatus: nil, isBusy: false,
           warning: nil,
           expectedText: "running", expectedColor: .running),
      // Not running locally but reachable per GitHub — yellow-dot idle.
      Case(label: "remote online",
           isRunning: false, githubStatus: .online, isBusy: false,
           warning: nil,
           expectedText: "online", expectedColor: .idle),
      Case(label: "offline",
           isRunning: false, githubStatus: .offline, isBusy: false,
           warning: nil,
           expectedText: "offline", expectedColor: .offline),
      // Deliberate fallback policy: unrecognised GitHub statuses read as offline.
      Case(label: "unknown is offline",
           isRunning: false, githubStatus: .unknown("draining"), isBusy: false,
           warning: nil,
           expectedText: "offline", expectedColor: .offline),
    ]

    for testCase in cases {
      let runner = makeRunnerModel(
        isRunning: testCase.isRunning,
        isBusy: testCase.isBusy,
        // `nil` and `.offline` resolve identically when the local process is down;
        // while running, `githubStatus` only matters when it is `.busy`.
        githubStatus: testCase.githubStatus ?? .offline,
        lifecycleWarning: testCase.warning
      )

      #expect(runner.displayStatus == testCase.expectedText, "\(testCase.label)")
      #expect(runner.statusColor == testCase.expectedColor, "\(testCase.label)")
    }
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
