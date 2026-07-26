// XCTestBridge.swift
// GitHubClientTests
//
// Sentinel XCTestCase so the XCTest runner finds at least one suite and does
// not exit with code 1 before Swift Testing finishes its async test run.
// All real tests use Swift Testing (@Test / @Suite).
import XCTest

final class XCTestBridge: XCTestCase {
  func testPlaceholder() {
    // Intentionally empty — keeps the XCTest runner alive until
    // Swift Testing completes its own run.
  }
}
