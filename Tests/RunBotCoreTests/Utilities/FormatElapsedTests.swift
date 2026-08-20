// FormatElapsedTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - FormatElapsedTests

@Suite("formatElapsed")
struct FormatElapsedTests {

  // MARK: - Sentinel values (nil start)

  /// `start: nil, isCompleted: false` → not yet started sentinel.
  @Test func nilStartNotCompletedReturnsZero() {
    #expect(formatElapsed(start: nil, end: nil, isCompleted: false) == "00:00")
  }

  /// `start: nil, isCompleted: true` → timing unavailable sentinel.
  @Test func nilStartCompletedReturnsDashes() {
    #expect(formatElapsed(start: nil, end: nil, isCompleted: true) == "--:--")
  }

  // MARK: - Known intervals

  /// 99 minutes 59 seconds — upper boundary of mm:ss display.
  @Test func ninetyNineMinutesFormatsCorrectly() {
    let start = Date()
    let end = start.addingTimeInterval(99 * 60 + 59)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "99:59")
  }

  // MARK: - Negative interval guard

  /// When `end` is before `start` the result must be `"00:00"`, not negative.
  @Test func endBeforeStartClampsToZero() {
    let start = Date()
    let end = start.addingTimeInterval(-30)
    #expect(formatElapsed(start: start, end: end, isCompleted: false) == "00:00")
  }

  // MARK: - Live clock (end: nil)

  /// When `end` is nil the function uses `Date()` — assert the output matches
  /// the `mm:ss` format without pinning an exact value.
  @Test func nilEndUsesCurrentDateAndMatchesFormat() {
    let start = Date().addingTimeInterval(-5)
    let result = formatElapsed(start: start, end: nil, isCompleted: false)
    let isMMSS = result.range(of: #"^\d{2}:\d{2}$"#, options: .regularExpression) != nil
    #expect(isMMSS)
  }
}
