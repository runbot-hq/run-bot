// WorkflowDurationTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - formatWorkflowDuration tests
//
// ActionRowView.formatWorkflowDuration is private to the RunBot module, so we
// test the identical pure logic here as a file-private helper. Any change to
// the formatter contract must update both this copy and the production version.

private func formatWorkflowDuration(_ duration: TimeInterval) -> String {
    let totalSeconds = Int(max(0, duration).rounded())
    let hours   = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60

    var parts: [String] = []
    if hours   > 0 { parts.append("\(hours)h") }
    if minutes > 0 { parts.append("\(minutes)min") }
    if seconds > 0 || parts.isEmpty { parts.append("\(seconds)sec") }
    return parts.joined(separator: " ")
}

@Suite("formatWorkflowDuration")
struct FormatWorkflowDurationTests {

    @Test func zeroSeconds() {
        #expect(formatWorkflowDuration(0) == "0sec")
    }

    @Test func thirtyTwoSeconds() {
        #expect(formatWorkflowDuration(32) == "32sec")
    }

    @Test func fourMinutesExact() {
        #expect(formatWorkflowDuration(240) == "4min")
    }

    @Test func fourMinutesThirtyTwoSeconds() {
        #expect(formatWorkflowDuration(272) == "4min 32sec")
    }

    @Test func oneHourExact() {
        #expect(formatWorkflowDuration(3_600) == "1h")
    }

    @Test func oneHourFourMinutes() {
        #expect(formatWorkflowDuration(3_840) == "1h 4min")
    }

    @Test func oneHourFourMinutesThirtyTwoSeconds() {
        #expect(formatWorkflowDuration(3_872) == "1h 4min 32sec")
    }

    @Test func twentyFiveHoursOneMinuteOneSecond() {
        #expect(formatWorkflowDuration(90_061) == "25h 1min 1sec")
    }

    @Test func fractionalSecondsRoundUp() {
        #expect(formatWorkflowDuration(4.7) == "5sec")
    }

    @Test func fractionalSecondsRoundDown() {
        #expect(formatWorkflowDuration(4.2) == "4sec")
    }

    @Test func negativeInputClampedToZero() {
        #expect(formatWorkflowDuration(-99) == "0sec")
    }
}

// MARK: - WorkflowActionGroup.completedDuration tests

@Suite("WorkflowActionGroup.completedDuration")
struct CompletedDurationTests {

    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Builds a minimal group with the given status/conclusion and timestamp pair.
    /// `firstJobStartedAt` and `lastJobCompletedAt` are passed directly to the
    /// stored-property init so they are independent of job construction.
    private func makeGroup(
        conclusion: JobConclusion?,
        start: Date?,
        end: Date?
    ) -> WorkflowActionGroup {
        let runStatus: JobStatus = conclusion == nil ? .inProgress : .completed
        let run = WorkflowRunRef(
            id: 1, name: "CI",
            status: runStatus,
            conclusion: conclusion,
            htmlUrl: nil
        )
        return WorkflowActionGroup(
            headSha: "abc1234",
            label: "abc1234",
            title: "CI",
            headBranch: nil,
            repo: "owner/repo",
            runs: [run],
            firstJobStartedAt: start,
            lastJobCompletedAt: end,
            createdAt: base
        )
    }

    @Test func completedWithValidTimestampsReturnsInterval() {
        let end = base.addingTimeInterval(272)
        let group = makeGroup(conclusion: .success, start: base, end: end)
        #expect(group.completedDuration == 272)
    }

    @Test func activeWorkflowReturnsNil() {
        let group = makeGroup(conclusion: nil, start: base, end: nil)
        #expect(group.completedDuration == nil)
    }

    @Test func loadingWorkflowReturnsNil() {
        // No conclusion, no timestamps — loading state.
        let group = makeGroup(conclusion: nil, start: nil, end: nil)
        #expect(group.completedDuration == nil)
    }

    @Test func missingStartReturnsNil() {
        let group = makeGroup(conclusion: .success, start: nil, end: base)
        #expect(group.completedDuration == nil)
    }

    @Test func missingEndReturnsNil() {
        let group = makeGroup(conclusion: .success, start: base, end: nil)
        #expect(group.completedDuration == nil)
    }

    @Test func endBeforeStartReturnsNil() {
        let start = base.addingTimeInterval(100)
        let group = makeGroup(conclusion: .success, start: start, end: base)
        #expect(group.completedDuration == nil)
    }

    @Test func failedWorkflowReturnsDuration() {
        let end = base.addingTimeInterval(60)
        let group = makeGroup(conclusion: .failure, start: base, end: end)
        #expect(group.completedDuration == 60)
    }

    @Test func cancelledWorkflowReturnsDuration() {
        let end = base.addingTimeInterval(30)
        let group = makeGroup(conclusion: .cancelled, start: base, end: end)
        #expect(group.completedDuration == 30)
    }
}
