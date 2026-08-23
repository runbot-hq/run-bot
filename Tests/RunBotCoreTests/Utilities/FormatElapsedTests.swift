// FormatElapsedTests.swift
// RunBotCoreTests
import Foundation
import Testing
@testable import RunBotCore

@Suite("formatElapsed")
struct FormatElapsedTests {

    @Test
    func formattingContract() {
        let origin = Date(timeIntervalSinceReferenceDate: 10_000)

        let cases: [
            (
                label: String,
                start: Date?,
                end: Date?,
                completed: Bool,
                now: Date,
                expected: String
            )
        ] = [
            ("not started",             nil,    nil,                              false, origin,                          "00:00"),
            ("completed without timing", nil,    nil,                              true,  origin,                          "--:--"),
            ("running uses injected clock", origin, nil,                          false, origin.addingTimeInterval(90),   "01:30"),
            ("completed uses end",       origin, origin.addingTimeInterval(167),  true,  origin.addingTimeInterval(999),  "02:47"),
            ("negative duration clamps", origin, origin.addingTimeInterval(-10),  true,  origin,                          "00:00"),
            ("minutes are not hour-wrapped", origin, origin.addingTimeInterval(6_000), true, origin,                      "100:00"),
        ]

        for testCase in cases {
            #expect(
                formatElapsed(
                    start: testCase.start,
                    end: testCase.end,
                    isCompleted: testCase.completed,
                    now: testCase.now
                ) == testCase.expected,
                #"\#(testCase.label)"#
            )
        }
    }
}
