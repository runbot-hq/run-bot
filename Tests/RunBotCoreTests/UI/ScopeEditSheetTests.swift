// ScopeEditSheetTests.swift
// RunBotCoreTests
// Tests for the atomic-save contract introduced by the ScopeEditSheet DI rewrite — refs #1540.
import Foundation
import RunBotCore
import Testing

// MARK: - Fake store

/// In-memory stand-in for `ScopePreferencesStoreProtocol` (Actor-constrained).
/// Records every `setPreferences(_:for:)` call so tests can assert
/// that exactly one write occurred and that it carried the correct values.
actor FakeScopePreferencesStore: ScopePreferencesStoreProtocol {

  // MARK: Stored state

  /// Backing storage keyed by scope string.
  private var store: [String: ScopePreferences] = [:]

  /// Ordered log of every `setPreferences` invocation.
  private(set) var writeLog: [(scope: String, prefs: ScopePreferences)] = []

  // MARK: ScopePreferencesStoreProtocol

  /// Returns the stored preferences for `scope`, or a default snapshot if none exists.
  func preferences(for scope: String) -> ScopePreferences {
    store[scope] ?? ScopePreferences()
  }

  /// Records the write and updates the in-memory store.
  func setPreferences(_ prefs: ScopePreferences, for scope: String) {
    store[scope] = prefs
    writeLog.append((scope: scope, prefs: prefs))
  }

  /// Returns the display name (alias if set, otherwise the raw scope string).
  func displayName(for scope: String) -> String {
    store[scope]?.alias ?? scope
  }

  func alias(for scope: String) -> String? {
    store[scope]?.alias
  }

  func setAlias(_ alias: String?, for scope: String) {
    var prefs = store[scope] ?? ScopePreferences()
    prefs.alias = alias
    store[scope] = prefs
  }

  func pollingInterval(for scope: String) -> Int? {
    store[scope]?.pollingInterval
  }

  func setPollingInterval(_ interval: Int?, for scope: String) {
    var prefs = store[scope] ?? ScopePreferences()
    prefs.pollingInterval = interval
    store[scope] = prefs
  }

  func notifyOnSuccess(for scope: String) -> Bool? {
    store[scope]?.notifyOnSuccess
  }

  func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
    var prefs = store[scope] ?? ScopePreferences()
    prefs.notifyOnSuccess = value
    store[scope] = prefs
  }

  func notifyOnFailure(for scope: String) -> Bool? {
    store[scope]?.notifyOnFailure
  }

  func setNotifyOnFailure(_ value: Bool?, for scope: String) {
    var prefs = store[scope] ?? ScopePreferences()
    prefs.notifyOnFailure = value
    store[scope] = prefs
  }

  func cleanUp(scope: String) {
    store.removeValue(forKey: scope)
    writeLog.removeAll()
  }

  func modifyPreferences(
    for scope: String, with mutation: @Sendable (inout ScopePreferences) -> Void
  ) {
    var prefs = store[scope] ?? ScopePreferences()
    mutation(&prefs)
    store[scope] = prefs
  }

  // MARK: Convenience

  /// Seeds the store with a known value so tests can control the initial state.
  func seed(_ prefs: ScopePreferences, for scope: String) {
    store[scope] = prefs
  }
}

// MARK: - Helpers

/// Mimics the save logic from `ScopeEditSheet.confirmSave()`.
/// Extracted here so the core contract can be tested without importing SwiftUI.
private func confirmSave(
  scope: String,
  updated: ScopePreferences,
  into store: any ScopePreferencesStoreProtocol
) async {
  await store.setPreferences(updated, for: scope)
}

// MARK: - Test suite

@Suite("ScopeEditSheet atomic save")
struct ScopeEditSheetTests {

  // MARK: Single-write contract

  /// Verifies that `confirmSave` calls `setPreferences` exactly once per invocation — no duplicate writes.
  @Test("confirmSave writes exactly once")
  func confirmSaveWritesExactlyOnce() async {
    let fake = FakeScopePreferencesStore()
    let prefs = ScopePreferences(alias: "My Org")
    await confirmSave(scope: "eoncode", updated: prefs, into: fake)
    #expect(await fake.writeLog.count == 1)
  }

  /// Verifies that `confirmSave` writes to the scope key that was passed in, not to any other key.
  @Test("confirmSave targets the correct scope")
  func confirmSaveTargetsCorrectScope() async {
    let fake = FakeScopePreferencesStore()
    let prefs = ScopePreferences(alias: "My Repo")
    await confirmSave(scope: "runbot-hq/run-bot", updated: prefs, into: fake)
    #expect(await fake.writeLog.first?.scope == "runbot-hq/run-bot")
  }

  // MARK: No spurious writes

  /// Verifies that calling `preferences(for:)` does not produce any entry in the write log.
  @Test("reading preferences does not produce a write")
  func readingDoesNotWrite() async {
    let fake = FakeScopePreferencesStore()
    await fake.seed(ScopePreferences(alias: "Seeded"), for: "acme")
    _ = await fake.preferences(for: "acme")
    #expect(await fake.writeLog.isEmpty)
  }

  /// Verifies that saving preferences for one scope does not modify the stored value for any other scope.
  @Test("confirmSave for one scope does not touch another scope")
  func saveDoesNotCrossContaminateScopes() async {
    let fake = FakeScopePreferencesStore()
    await fake.seed(ScopePreferences(alias: "Original"), for: "other-scope")
    await confirmSave(scope: "my-scope", updated: ScopePreferences(alias: "New"), into: fake)
    let untouched = await fake.preferences(for: "other-scope")
    #expect(untouched.alias == "Original")
  }

  // MARK: Round-trip

  /// Verifies that `preferences(for:)` returns exactly the value that was written by `confirmSave`.
  @Test("preferences(for:) returns the value written by confirmSave")
  func roundTrip() async {
    let fake = FakeScopePreferencesStore()
    let prefs = ScopePreferences(alias: "Round Trip")
    await confirmSave(scope: "rt-scope", updated: prefs, into: fake)
    let readBack = await fake.preferences(for: "rt-scope")
    #expect(readBack.alias == "Round Trip")
  }

  /// Verifies that a second `confirmSave` for the same scope overwrites the first value, and that the write log records both calls.
  @Test("second confirmSave overwrites the first")
  func secondSaveOverwritesFirst() async {
    let fake = FakeScopePreferencesStore()
    await confirmSave(scope: "s", updated: ScopePreferences(alias: "v1"), into: fake)
    await confirmSave(scope: "s", updated: ScopePreferences(alias: "v2"), into: fake)
    #expect(await fake.writeLog.count == 2)
    #expect(await fake.preferences(for: "s").alias == "v2")
  }
}
