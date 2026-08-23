// PollIntervalStrategyTests.swift
// RunBotCoreTests

import Foundation
import Testing
@testable import RunBotCore

// MARK: - Helpers

private extension Date {
  /// Returns a Date `seconds` from now.
  static func fromNow(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSinceNow: seconds)
  }
}

// MARK: - PollIntervalStrategyTests

/// Three policy contracts for ``PollIntervalStrategy``:
///   rateLimitPolicyContract  - hard wall wins; known reset gets grace, expired floors at 30,
///                              unknown falls back to a fixed 60 s
///   headroomPolicyContract   - proactive cooldown below remaining < 50, incl. the exact
///                              boundary and priority over active mode
///   normalCadenceContract    - busy-runner ladder in active mode plus idle exponential
///                              backoff capped at 300 s
@Suite("PollIntervalStrategy")
struct PollIntervalStrategyTests {

  // MARK: - Rate-limit policy

  struct RateLimitCase {
    let label: String
    let resetOffset: TimeInterval?
    let hasActiveWork: Bool
    let remaining: Int
    let expected: TimeInterval
    var tolerance: TimeInterval = 0
  }

  @Test("Rate-limited branch wins → known reset grace / expired floor / unknown fallback")
  func rateLimitPolicyContract() {
    let cases: [RateLimitCase] = [
      // Known future reset → max(30, reset + 5).
      RateLimitCase(label: "future reset",
                    resetOffset: 100, hasActiveWork: false,
                    remaining: PollIntervalStrategy.rateLimitUnavailable,
                    expected: 105, tolerance: 1),
      // Expired reset floors at 30 s.
      RateLimitCase(label: "expired reset",
                    resetOffset: -60, hasActiveWork: false,
                    remaining: PollIntervalStrategy.rateLimitUnavailable,
                    expected: 30),
      // Unknown reset → fixed fallback.
      RateLimitCase(label: "no reset date",
                    resetOffset: nil, hasActiveWork: false,
                    remaining: PollIntervalStrategy.rateLimitUnavailable,
                    expected: 60),
      // Priority: the hard wall overrides active mode.
      RateLimitCase(label: "overrides active mode",
                    resetOffset: nil, hasActiveWork: true,
                    remaining: PollIntervalStrategy.rateLimitUnavailable,
                    expected: 60),
      // Priority: the hard wall overrides headroom cooldown.
      RateLimitCase(label: "overrides headroom cooldown",
                    resetOffset: nil, hasActiveWork: false,
                    remaining: 49,
                    expected: 60),
    ]

    for testCase in cases {
      let result = PollIntervalStrategy.next(
        hasActiveWork: testCase.hasActiveWork,
        consecutiveIdleTicks: 0,
        busyRunnerCount: 0,
        isRateLimited: true,
        rateLimitResetDate: testCase.resetOffset.map(Date.fromNow),
        rateLimitRemaining: testCase.remaining
      )
      #expect(abs(result - testCase.expected) <= testCase.tolerance,
              "case=\(testCase.label), result=\(result)")
    }
  }

  // MARK: - Headroom policy

  struct HeadroomCase {
    let label: String
    let remaining: Int
    let resetOffset: TimeInterval?
    let hasActiveWork: Bool
    let expected: TimeInterval
    var tolerance: TimeInterval = 0
  }

  @Test("Headroom < 50 → max(60, reset) / floor / 300 s; boundary at exactly 50 skips branch")
  func headroomPolicyContract() {
    let cases: [HeadroomCase] = [
      // Below threshold with known future reset → max(60, reset).
      HeadroomCase(label: "known reset",
                   remaining: 49, resetOffset: 200, hasActiveWork: false,
                   expected: 200, tolerance: 1),
      // Reset closer than the 60 s floor.
      HeadroomCase(label: "near reset floors at 60",
                   remaining: 49, resetOffset: 10, hasActiveWork: false,
                   expected: 60),
      // Unknown reset → fixed 300 s cooldown.
      HeadroomCase(label: "no reset date",
                   remaining: 49, resetOffset: nil, hasActiveWork: false,
                   expected: 300),
      // Boundary: remaining == 50 does NOT enter the headroom branch.
      HeadroomCase(label: "boundary 50 keeps active cadence",
                   remaining: 50, resetOffset: nil, hasActiveWork: true,
                   expected: PollIntervalStrategy.activeIntervalFast),
      // Headroom wins over active mode.
      HeadroomCase(label: "overrides active mode",
                   remaining: 49, resetOffset: nil, hasActiveWork: true,
                   expected: 300),
    ]

    for testCase in cases {
      let result = PollIntervalStrategy.next(
        hasActiveWork: testCase.hasActiveWork,
        consecutiveIdleTicks: 0,
        busyRunnerCount: 0,
        isRateLimited: false,
        rateLimitResetDate: testCase.resetOffset.map(Date.fromNow),
        rateLimitRemaining: testCase.remaining
      )
      #expect(abs(result - testCase.expected) <= testCase.tolerance,
              "case=\(testCase.label), result=\(result)")
    }
  }

  // MARK: - Normal cadence

  @Test("Active busy-runner ladder + idle exponential backoff capped at 300 s")
  func normalCadenceContract() {
    struct ActiveCase {
      let busyRunnerCount: Int
      let expectedInterval: TimeInterval
    }

    let activeCases: [ActiveCase] = [
      ActiveCase(busyRunnerCount: 0,  expectedInterval: PollIntervalStrategy.activeIntervalFast),
      ActiveCase(busyRunnerCount: 5,  expectedInterval: PollIntervalStrategy.activeIntervalFast),
      ActiveCase(busyRunnerCount: 6,  expectedInterval: PollIntervalStrategy.activeIntervalMid),
      ActiveCase(busyRunnerCount: 9,  expectedInterval: PollIntervalStrategy.activeIntervalMid),
      ActiveCase(busyRunnerCount: 10, expectedInterval: PollIntervalStrategy.activeIntervalSlow),
      ActiveCase(busyRunnerCount: 20, expectedInterval: PollIntervalStrategy.activeIntervalSlow),
    ]

    for testCase in activeCases {
      let result = PollIntervalStrategy.next(
        hasActiveWork: true,
        consecutiveIdleTicks: 0,
        busyRunnerCount: testCase.busyRunnerCount,
        isRateLimited: false,
        rateLimitResetDate: nil,
        rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
      )
      #expect(result == testCase.expectedInterval,
              "busyRunnerCount=\(testCase.busyRunnerCount)")
    }

    struct IdleCase {
      let consecutiveIdleTicks: Int
      let expectedInterval: TimeInterval
    }

    let idleCases: [IdleCase] = [
      // tick 0: error-only path (15 * 2^(0-1) = 7.5 s)
      IdleCase(consecutiveIdleTicks: 0,  expectedInterval: 7.5),
      // normal production curve starts at tick 1
      IdleCase(consecutiveIdleTicks: 1,  expectedInterval: 15),
      IdleCase(consecutiveIdleTicks: 2,  expectedInterval: 30),
      IdleCase(consecutiveIdleTicks: 3,  expectedInterval: 60),
      IdleCase(consecutiveIdleTicks: 4,  expectedInterval: 120),
      IdleCase(consecutiveIdleTicks: 5,  expectedInterval: 240),
      IdleCase(consecutiveIdleTicks: 6,  expectedInterval: 300),   // capped at idleMax
      IdleCase(consecutiveIdleTicks: 99, expectedInterval: 300),   // deep idle — still capped
    ]

    for testCase in idleCases {
      let result = PollIntervalStrategy.next(
        hasActiveWork: false,
        consecutiveIdleTicks: testCase.consecutiveIdleTicks,
        busyRunnerCount: 0,
        isRateLimited: false,
        rateLimitResetDate: nil,
        rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
      )
      #expect(result == testCase.expectedInterval,
              "consecutiveIdleTicks=\(testCase.consecutiveIdleTicks)")
    }
  }
}
