// APICallCounter+TestSeam.swift
// GitHubClientTests
//
// Test-only extensions on APICallCounter for seeding and resetting state
// without real time travel. Compiled only in the test target.
import Foundation

@testable import GitHubClient

extension APICallCounter {
  /// Seeds the rolling buffer with pre-built `ContinuousClock.Instant` values.
  ///
  /// Use `ContinuousClock.now.advanced(by: .seconds(-n))` to create
  /// instants in the past.
  func seed(timestamps: [ContinuousClock.Instant]) {
    self.timestamps = timestamps
  }

  /// Resets the rolling buffer to empty.
  func reset() {
    timestamps = []
  }
}
