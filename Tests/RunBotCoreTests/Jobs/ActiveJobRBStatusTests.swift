// ActiveJobRBStatusTests.swift
// RunBotCoreTests
import Testing

@testable import RunBotCore

// MARK: - ActiveJob.rbStatus

@Suite("ActiveJob.rbStatus")
struct ActiveJobRBStatusTests {

  // MARK: Conclusion cases

  @Test func conclusionStatusMapping() {
    let cases: [(JobConclusion, RBStatus)] = [
      (.success, .success),
      (.failure, .failed),
    ]
    for (conclusion, expected) in cases {
      let job = ActiveJob(id: 1, name: "j", status: .completed, conclusion: conclusion)
      #expect(job.rbStatus == expected, "conclusion \(conclusion) should map to \(expected)")
    }
  }

  @Test func cancelledConclusionMapsToCancelled() {
    let job = ActiveJob(id: 3, name: "j", status: .completed, conclusion: .cancelled)
    #expect(job.rbStatus == .cancelled)
  }

  @Test func skippedConclusionMapsToSkipped() {
    let job = ActiveJob(id: 4, name: "j", status: .completed, conclusion: .skipped)
    #expect(job.rbStatus == .skipped)
  }

  @Test func neutralConclusionMapsToUnknown() {
    let job = ActiveJob(id: 5, name: "j", status: .completed, conclusion: .neutral)
    #expect(job.rbStatus == .unknown)
  }

  // MARK: Status-only cases (no conclusion)

  @Test func inProgressStatusMapsToInProgress() {
    let job = ActiveJob(id: 6, name: "j", status: .inProgress)
    #expect(job.rbStatus == .inProgress)
  }

  @Test func queuedStatusMapsToQueued() {
    let job = ActiveJob(id: 7, name: "j", status: .queued)
    #expect(job.rbStatus == .queued)
  }

  @Test func conclusionTakesPrecedenceOverStatus() {
    let job = ActiveJob(id: 8, name: "j", status: .inProgress, conclusion: .success)
    #expect(job.rbStatus == .success)
  }

  // MARK: API race condition

  /// A job with status == .completed but no conclusion is an API race (see asCompleted).
  /// Must return .unknown, not .queued.
  @Test func completedStatusWithNoConclusionMapsToUnknown() {
    let job = ActiveJob(id: 9, name: "j", status: .completed)
    #expect(job.rbStatus == .unknown)
  }
}
