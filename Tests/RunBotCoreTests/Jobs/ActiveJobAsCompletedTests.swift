// ActiveJobAsCompletedTests.swift
// RunBotCoreTests
import Testing
import Foundation
import GitHubClient
@testable import RunBotCore

// MARK: - ActiveJob.asCompleted

@Suite("ActiveJob.asCompleted")
struct ActiveJobAsCompletedTests {

  // MARK: Helpers

  /// ISO-8601 string used as an explicit completedAt in some fixtures.
  private static let knownDateString = "2024-01-15T10:30:00Z"
  private static let knownDate: Date = {
    ISO8601DateFormatter().date(from: knownDateString)!
  }()

  /// A fallback `Date` passed to `asCompleted(at:)`.
  private static let fallback = Date(timeIntervalSinceReferenceDate: 999_000)

  /// Returns a minimal `ActiveJob` suitable for `asCompleted` tests.
  ///
  /// - Parameters:
  ///   - status:      Job status string. Defaults to `"in_progress"`.
  ///   - conclusion:  Optional conclusion string. Defaults to `nil`.
  ///   - completedAt: Optional explicit completedAt `Date`. Defaults to `nil`.
  ///   - scope:       Scope string injected into the job. Defaults to `"org/repo"`.
  private func makeJob(
    status: String = "in_progress",
    conclusion: String? = nil,
    completedAt: Date? = nil,
    scope: String? = "org/repo"
  ) -> ActiveJob {
    ActiveJob(
      id: 42,
      name: "build",
      status: status,
      conclusion: conclusion,
      scope: scope,
      completedAt: completedAt
    )
  }

  // MARK: Status and isDimmed

  @Test func asCompleted_setsStatusCompletedAndDimmed() {
    let result = makeJob().asCompleted(at: Self.fallback)
    #expect(result.jobStatus == .completed)
    #expect(result.isDimmed)
  }

  // MARK: Missing timestamp uses fallback; nil conclusion becomes .neutral; scope preserved

  @Test func asCompleted_fallbackTimestampAndNeutralConclusion() {
    let result = makeJob(conclusion: nil, completedAt: nil, scope: "myorg/myrepo")
      .asCompleted(at: Self.fallback)
    // status + dimming
    #expect(result.jobStatus == .completed)
    #expect(result.isDimmed)
    // nil conclusion → .neutral
    #expect(result.jobConclusion == .neutral)
    // fallback timestamp written when completedAt is nil
    let diff = abs((result.completedDate ?? .distantPast).timeIntervalSince(Self.fallback))
    #expect(diff < 1)
    // scope forwarded
    #expect(result.scope == "myorg/myrepo")
  }

  // MARK: Existing timestamp and conclusion are preserved

  @Test func asCompleted_existingTimestampAndConclusionPreserved() {
    let result = makeJob(conclusion: "failure", completedAt: Self.knownDate, scope: nil)
      .asCompleted(at: Self.fallback)
    // existing conclusion kept
    #expect(result.jobConclusion == .failure)
    // existing completedAt not overwritten
    let diff = abs((result.completedDate ?? .distantPast).timeIntervalSince(Self.knownDate))
    #expect(diff < 1)
    // nil scope forwarded
    #expect(result.scope == nil)
  }

  // MARK: All other fields preserved

  @Test func asCompleted_allOtherFieldsPreserved() {
    let step = JobStep(
      id: 1,
      name: "checkout",
      status: "completed",
      conclusion: "success"
    )
    let startedAtDate = Date(timeIntervalSinceReferenceDate: 500_000)
    let createdAtDate = Date(timeIntervalSinceReferenceDate: 499_000)
    let job = ActiveJob(
      id: 99,
      name: "deploy",
      status: "in_progress",
      htmlUrl: "https://github.com/org/repo/actions/runs/1",
      conclusion: "failure",
      isDimmed: false,
      runnerName: "my-runner",
      scope: "org/repo",
      startedAt: startedAtDate,
      completedAt: nil,
      createdAt: createdAtDate,
      steps: [step]
    )
    let fallback = Date(timeIntervalSinceReferenceDate: 600_000)
    let result = job.asCompleted(at: fallback)
    // Preserved fields
    #expect(result.id       == 99)
    #expect(result.name     == "deploy")
    #expect(result.htmlUrl  == "https://github.com/org/repo/actions/runs/1")
    #expect(result.runnerName == "my-runner")
    #expect(result.scope    == "org/repo")
    #expect(result.steps    == [step])
    let startDiff = abs((result.startDate ?? .distantPast).timeIntervalSince(startedAtDate))
    #expect(startDiff < 1)
    let createDiff = abs((result.createdDate ?? .distantPast).timeIntervalSince(createdAtDate))
    #expect(createDiff < 1)
    // Overridden fields
    #expect(result.jobStatus == .completed)
    #expect(result.isDimmed)
    let completedDiff = abs((result.completedDate ?? .distantPast).timeIntervalSince(fallback))
    #expect(completedDiff < 1)
    #expect(result.jobConclusion == .failure)
  }
}
