// WorkflowDurationTests.swift
// RunBot
import Foundation
import Testing

@testable import RunBotCore

@Suite("WorkflowDurationFormatter")
struct FormatWorkflowDurationTests {

    @Test func zeroSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 0) == "00:00")
    }

    @Test func threeSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 3) == "00:03")
    }

    @Test func thirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 32) == "00:32")
    }

    @Test func sixtySeconds() {
        #expect(WorkflowDurationFormatter.string(from: 60) == "01:00")
    }

    @Test func twoMinutesThreeSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 123) == "02:03")
    }

    @Test func fourMinutesThirtyTwoSeconds() {
        #expect(WorkflowDurationFormatter.string(from: 272) == "04:32")
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
        #expect(WorkflowDurationFormatter.string(from: 4.7) == "00:05")
    }

    @Test func fractionalSecondsRoundDown() {
        #expect(WorkflowDurationFormatter.string(from: 4.2) == "00:04")
    }

    @Test func negativeInputClampedToZero() {
        #expect(WorkflowDurationFormatter.string(from: -99) == "00:00")
    }
}
