// AppPreferencesStoreAutomaticUpdatesTests.swift
// RunBotCoreTests

import XCTest
@testable import RunBotCore

// MARK: - AppPreferencesStore.automaticUpdatesEnabled tests (#2501)

/// Tests for the `automaticUpdatesEnabled` preference introduced in #2501.
///
/// Each test injects an ephemeral `UserDefaults` suite so the real `.standard`
/// database is never touched. Pattern follows the existing betaChannel tests.
@MainActor
final class AppPreferencesStoreAutomaticUpdatesTests: XCTestCase {

    private func makeSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.\(UUID().uuidString)")!
    }

    // MARK: - Default value

    func testDefaultsToTrue() {
        let store = AppPreferencesStore(store: makeSuite())
        XCTAssertTrue(
            store.automaticUpdatesEnabled,
            "automaticUpdatesEnabled must default to true so existing installs " +
            "keep receiving updates without any action"
        )
    }

    // MARK: - Persistence

    func testPersistsFalse() {
        let suite = makeSuite()
        let store = AppPreferencesStore(store: suite)
        store.automaticUpdatesEnabled = false
        let store2 = AppPreferencesStore(store: suite)
        XCTAssertFalse(
            store2.automaticUpdatesEnabled,
            "false must survive a round-trip through UserDefaults"
        )
    }

    func testPersistsTrue() {
        let suite = makeSuite()
        let store = AppPreferencesStore(store: suite)
        store.automaticUpdatesEnabled = false
        store.automaticUpdatesEnabled = true
        let store2 = AppPreferencesStore(store: suite)
        XCTAssertTrue(
            store2.automaticUpdatesEnabled,
            "re-enabling must persist as true"
        )
    }

    // MARK: - Interaction with betaChannel

    func testDisablingDoesNotResetBetaChannel() {
        let store = AppPreferencesStore(store: makeSuite())
        store.betaChannel = true
        store.automaticUpdatesEnabled = false
        XCTAssertTrue(
            store.betaChannel,
            "betaChannel must be preserved when automaticUpdatesEnabled is set to false"
        )
    }

    func testEnablingDoesNotChangeBetaChannel() {
        let store = AppPreferencesStore(store: makeSuite())
        store.betaChannel = false
        store.automaticUpdatesEnabled = false
        store.automaticUpdatesEnabled = true
        XCTAssertFalse(
            store.betaChannel,
            "betaChannel must be preserved when automaticUpdatesEnabled is set to true"
        )
    }

    // MARK: - Idempotency

    func testIdempotentWriteFalse() {
        let store = AppPreferencesStore(store: makeSuite())
        store.automaticUpdatesEnabled = false
        store.automaticUpdatesEnabled = false  // second write — must be a no-op
        XCTAssertFalse(store.automaticUpdatesEnabled)
    }

    func testIdempotentWriteTrue() {
        let store = AppPreferencesStore(store: makeSuite())
        store.automaticUpdatesEnabled = true  // same as default — no-op
        store.automaticUpdatesEnabled = true
        XCTAssertTrue(store.automaticUpdatesEnabled)
    }

    // MARK: - Independence from betaChannel key

    func testAutomaticUpdatesAndBetaChannelUseSeparateKeys() {
        let suite = makeSuite()
        let store = AppPreferencesStore(store: suite)
        store.automaticUpdatesEnabled = false
        store.betaChannel = true
        // Both must round-trip independently.
        let store2 = AppPreferencesStore(store: suite)
        XCTAssertFalse(store2.automaticUpdatesEnabled)
        XCTAssertTrue(store2.betaChannel)
    }
}
