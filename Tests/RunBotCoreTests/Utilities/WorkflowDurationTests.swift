// WorkflowDurationTests.swift
// RunBot
import Foundation
import Testing

@testable import RunBotCore

@Suite("WorkflowDurationFormatter")
struct FormatWorkflowDurationTests {

    @Test func zeroSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 0) == "0:00")
    }

    @Test func threeSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 3) == "0:03")
    }

    @Test func thirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 32) == "0:32")
    }

    @Test func sixtySeconds() {
        #expect(WorkflowDurationFormatter.string(from: 60) == "1:00")
    }

    @Test func twoMinutesThreeSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 123) == "2:03")
    }

    @Test func fourMinutesThirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 272) == "4:32")
    }

    @Test func fiftyNineMinutesFiftyNineSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 3_599) == "59:59")
    }

    @Test func oneHourExact() {
        #expect(WorkflowDurationFormatter.string(from: 3_600) == "1:00:00")
    }

    @Test func oneHourFourMinutesThirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 3_872) == "1:04:32")
    }

    @Test func twentyFiveHoursOneMinuteOneSecond() {
        #expect(WorkflowDurationFormatter.string(from: 90_061) == "25:01:01")
    }

    @Test func fractionalSecondsRoundUp() {
        #expect(WorkflowDurationFormatter.string(from: 4.7) == "0:05")
    }

    @Test func fractionalSecondsRoundDown() {
        #expect(WorkflowDurationFormatter.string(from: 4.2) == "0:04")
    }

    @Test func negativeInputClampedToZero() {
        #expect(WorkflowDurationFormatter.string(from: -99) == "0:00")
    }
}
