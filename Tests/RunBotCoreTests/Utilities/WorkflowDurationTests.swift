// WorkflowDurationTests.swift
// RunBot
import Foundation
import Testing

@testable import RunBotCore

@Suite("WorkflowDurationFormatter")
struct FormatWorkflowDurationTests {

    @Test func zeroSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 0) == "0sec")
    }

    @Test func thirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 32) == "32sec")
    }

    @Test func fourMinutesExact() {
        #expect(WorkflowDurationFormatter.string(from: 240) == "4min")
    }

    @Test func fourMinutesThirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 272) == "4min 32sec")
    }

    @Test func oneHourExact() {
        #expect(WorkflowDurationFormatter.string(from: 3_600) == "1h")
    }

    @Test func oneHourFourMinutes() {
        #expect(WorkflowDurationFormatter.string(from: 3_840) == "1h 4min")
    }

    @Test func oneHourFourMinutesThirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 3_872) == "1h 4min 32sec")
    }

    @Test func twentyFiveHoursOneMinuteOneSecond() {
        #expect(WorkflowDurationFormatter.string(from: 90_061) == "25h 1min 1sec")
    }

    @Test func fractionalSecondsRoundUp() {
        #expect(WorkflowDurationFormatter.string(from: 4.7) == "5sec")
    }

    @Test func fractionalSecondsRoundDown() {
        #expect(WorkflowDurationFormatter.string(from: 4.2) == "4sec")
    }

    @Test func negativeInputClampedToZero() {
        #expect(WorkflowDurationFormatter.string(from: -99) == "0sec")
    }
}
