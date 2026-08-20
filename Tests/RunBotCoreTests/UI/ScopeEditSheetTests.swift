// ScopeEditSheetTests.swift
// RunBotCoreTests
// Store contract tests for ScopePreferencesStoreProtocol — originally introduced
// alongside the ScopeEditSheet DI rewrite (#1540); confirmSave helper removed in
// #2009 when the sheet became read-only and no longer writes on Save.
import Foundation
import RunBotCore
import Testing

// MARK: - Fake store

/// In-memory stand-in for `ScopePreferencesStoreProtocol` (Actor-constrained).
/// Records every `setPreferences(_:for:)` call so tests can assert
/// write isolation and cross-scope safety.
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

// MARK: - Test suite

@Suite("ScopePreferencesStore contract")
struct ScopeEditSheetTests {

  /// Verifies that writing preferences for one scope does not modify the stored value for any other scope.
  @Test("write for one scope does not touch another scope")
  func saveDoesNotCrossContaminateScopes() async {
    let fake = FakeScopePreferencesStore()
    await fake.seed(ScopePreferences(alias: "Original"), for: "other-scope")
    await fake.setPreferences(ScopePreferences(alias: "New"), for: "my-scope")
    let untouched = await fake.preferences(for: "other-scope")
    #expect(untouched.alias == "Original")
  }

  // MARK: Round-trip

  /// Verifies that `preferences(for:)` returns exactly the value that was written.
  @Test("preferences(for:) returns the value written by setPreferences")
  func roundTrip() async {
    let fake = FakeScopePreferencesStore()
    let prefs = ScopePreferences(alias: "Round Trip")
    await fake.setPreferences(prefs, for: "rt-scope")
    let readBack = await fake.preferences(for: "rt-scope")
    #expect(readBack.alias == "Round Trip")
  }

  /// Verifies that a second write for the same scope overwrites the first, and that the write log records both calls.
  @Test("second write overwrites the first")
  func secondSaveOverwritesFirst() async {
    let fake = FakeScopePreferencesStore()
    await fake.setPreferences(ScopePreferences(alias: "v1"), for: "s")
    await fake.setPreferences(ScopePreferences(alias: "v2"), for: "s")
    #expect(await fake.writeLog.count == 2)
    #expect(await fake.preferences(for: "s").alias == "v2")
  }
}
