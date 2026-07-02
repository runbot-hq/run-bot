// AppUpdaterDefaultsTests.swift
// AppUpdaterTests
import Foundation
import Testing
@testable import AppUpdater

// MARK: - AppUpdaterDefaultsTests

/// Smoke-tests for `AppUpdater` static configuration.
///
/// `AppUpdaterDefaults` and `rehydrateCachedUpdateIfNewer` were removed in the
/// AppUpdater library-extraction refactor (issue #1860). The scoped
/// `UserDefaults` cache is superseded by `fixedZipURL` — the zip always lives
/// at a deterministic path under `~/Library/Caches/<schedulerIdentifier>/update.zip`
/// so no key-based persistence is required.
@MainActor
struct AppUpdaterDefaultsTests {

    // MARK: - checkInterval

    /// `AppUpdater.checkInterval` must be a positive `TimeInterval`.
    @Test func checkInterval_isPositive() {
        #expect(AppUpdater.checkInterval > 0)
    }

    #if DEBUG
    /// In DEBUG builds the interval defaults to 60 seconds for fast QA cycles.
    @Test func checkInterval_debug_defaultIs60Seconds() {
        #expect(AppUpdater.checkInterval == 60)
    }
    #else
    /// In release builds the interval is 24 hours.
    @Test func checkInterval_release_is24Hours() {
        #expect(AppUpdater.checkInterval == 24 * 60 * 60)
    }
    #endif
}
