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

@Suite("PollIntervalStrategy")
struct PollIntervalStrategyTests {

  // MARK: - Rate-limited (hard wall)

  @Test("Rate-limited with known reset date → max(30, resetDate + 5)")
  func rateLimitedWithResetDate() {
    // reset 100 s from now → expect 105 s (well above the 30 s floor)
    let reset = Date.fromNow(100)
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: true,
      rateLimitResetDate: reset,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result >= 105 - 1 && result <= 105 + 1)
  }

  @Test("Rate-limited with reset date in the past → floor of 30 s")
  func rateLimitedWithExpiredResetDate() {
    let reset = Date.fromNow(-60)  // already past
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: true,
      rateLimitResetDate: reset,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == 30)
  }

  @Test("Rate-limited with no reset date → 60 s")
  func rateLimitedNoResetDate() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: true,
      rateLimitResetDate: nil,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == 60)
  }

  // MARK: - Headroom cooldown (approaching rate limit)

  @Test("Headroom < 50 with known reset date → max(60, resetDate)")
  func headroomCooldownWithResetDate() {
    // reset 200 s from now → expect 200 s (above the 60 s floor)
    let reset = Date.fromNow(200)
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: false,
      rateLimitResetDate: reset,
      rateLimitRemaining: 49
    )
    #expect(result >= 200 - 1 && result <= 200 + 1)
  }

  @Test("Headroom < 50 with reset date producing value < 60 → floor of 60 s")
  func headroomCooldownWithNearResetDate() {
    let reset = Date.fromNow(10)  // only 10 s away → floor kicks in
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: false,
      rateLimitResetDate: reset,
      rateLimitRemaining: 49
    )
    #expect(result == 60)
  }

  @Test("Headroom < 50 with no reset date → 300 s")
  func headroomCooldownNoResetDate() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: 49
    )
    #expect(result == 300)
  }

  @Test("Headroom boundary: remaining == 50 → headroom branch NOT taken")
  func headroomBoundaryExactly50() {
    // With hasActiveWork=true and ≤5 busy, should be activeIntervalFast (1 s)
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 3,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: 50
    )
    #expect(result == PollIntervalStrategy.activeIntervalFast)
  }

  @Test("Headroom boundary: remaining == 51 → headroom branch NOT taken")
  func headroomBoundaryAbove50() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 3,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: 51
    )
    #expect(result == PollIntervalStrategy.activeIntervalFast)
  }

  @Test("Headroom boundary: remaining == 49 → headroom branch taken")
  func headroomBoundaryBelow50() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 3,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: 49
    )
    #expect(result == 300)  // no reset date → 300 s
  }

  // MARK: - Active mode (busy runner ladder)

  /// Input parameters for a single active-mode ladder test case.
  struct ActiveCase {
    /// Number of runners currently marked busy.
    let busyRunnerCount: Int
    /// The polling interval expected from `PollIntervalStrategy.next`.
    let expectedInterval: TimeInterval
  }

  @Test(
    "Active mode runner ladder",
    arguments: [
      ActiveCase(busyRunnerCount: 0,  expectedInterval: PollIntervalStrategy.activeIntervalFast),
      ActiveCase(busyRunnerCount: 1,  expectedInterval: PollIntervalStrategy.activeIntervalFast),
      ActiveCase(busyRunnerCount: 5,  expectedInterval: PollIntervalStrategy.activeIntervalFast),
      ActiveCase(busyRunnerCount: 6,  expectedInterval: PollIntervalStrategy.activeIntervalMid),
      ActiveCase(busyRunnerCount: 9,  expectedInterval: PollIntervalStrategy.activeIntervalMid),
      ActiveCase(busyRunnerCount: 10, expectedInterval: PollIntervalStrategy.activeIntervalSlow),
      ActiveCase(busyRunnerCount: 20, expectedInterval: PollIntervalStrategy.activeIntervalSlow),
    ]
  )
  func activeModeLadder(_ testCase: ActiveCase) {
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: testCase.busyRunnerCount,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == testCase.expectedInterval)
  }

  // MARK: - Idle mode (exponential backoff)

  /// Input parameters for a single idle-mode backoff test case.
  struct IdleCase {
    /// Number of consecutive idle poll cycles completed before this interval is computed.
    let consecutiveIdleTicks: Int
    /// The polling interval expected from `PollIntervalStrategy.next`.
    let expectedInterval: TimeInterval
  }

  @Test(
    "Idle mode exponential backoff",
    arguments: [
      IdleCase(consecutiveIdleTicks: 0, expectedInterval: 30),
      IdleCase(consecutiveIdleTicks: 1, expectedInterval: 60),
      IdleCase(consecutiveIdleTicks: 2, expectedInterval: 120),
      IdleCase(consecutiveIdleTicks: 3, expectedInterval: 240),
      IdleCase(consecutiveIdleTicks: 4, expectedInterval: 300),  // capped at idleMax
      IdleCase(consecutiveIdleTicks: 5, expectedInterval: 300),  // still capped
      IdleCase(consecutiveIdleTicks: 99, expectedInterval: 300), // deep idle — still capped
    ]
  )
  func idleModeBackoff(_ testCase: IdleCase) {
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: testCase.consecutiveIdleTicks,
      busyRunnerCount: 0,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == testCase.expectedInterval)
  }

  // MARK: - Priority ordering

  @Test("isRateLimited takes priority over hasActiveWork")
  func rateLimitedOverridesActive() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: true,
      rateLimitResetDate: nil,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == 60)  // rate-limited path, not active path
  }

  @Test("isRateLimited takes priority over headroom cooldown")
  func rateLimitedOverridesHeadroom() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: false,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: true,
      rateLimitResetDate: nil,
      rateLimitRemaining: 49  // headroom also triggered — rate-limit wins
    )
    #expect(result == 60)
  }

  @Test("Headroom cooldown takes priority over active mode")
  func headroomOverridesActive() {
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 0,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: 49
    )
    #expect(result == 300)  // headroom path, not active path
  }

  // MARK: - Int.max passthrough (Step 9 placeholder)

  @Test("rateLimitRemaining == Int.max → headroom branch is no-op")
  func intMaxPassthrough() {
    // Should fall through to active path
    let result = PollIntervalStrategy.next(
      hasActiveWork: true,
      consecutiveIdleTicks: 0,
      busyRunnerCount: 3,
      isRateLimited: false,
      rateLimitResetDate: nil,
      rateLimitRemaining: PollIntervalStrategy.rateLimitUnavailable
    )
    #expect(result == PollIntervalStrategy.activeIntervalFast)
  }
}

// MARK: - ActiveCase + IdleCase Sendable conformances (required by @Test arguments)
extension PollIntervalStrategyTests.ActiveCase: Sendable {}
extension PollIntervalStrategyTests.IdleCase: Sendable {}
