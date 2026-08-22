// LocalRunnerIndexTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - LocalRunnerIndexTests

/// Tests for `LocalRunnerIndex` — the `UserDefaults`-backed name -> install-path persistence layer.
///
/// Each test receives its own `UserDefaults` suite (UUID-namespaced) via `makeSuite()` so tests
/// are fully isolated from each other and from the app's real defaults. The suite is removed
/// after each test via `defer`.
///
/// `registerEmptyNameIsStoredAsIs` was removed in #1500 — the test body itself noted that
/// empty-name validation is the caller's responsibility. Testing an explicitly out-of-scope
/// no-op provides no regression value.
@Suite("LocalRunnerIndex")
struct LocalRunnerIndexTests {

  // MARK: - Helpers

  /// Returns a fresh, UUID-namespaced `UserDefaults` suite and its suite name.
  /// Callers are responsible for cleanup via `UserDefaults.standard.removePersistentDomain(forName:)`.
  private static func makeSuite() -> (UserDefaults, String) {
    let suiteName = "com.runbot.tests.LocalRunnerIndex.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Failed to create UserDefaults with suite name \(suiteName)")
    }
    return (defaults, suiteName)
  }

  // MARK: - register

  /// `register` stores the install path and makes it immediately readable.
  @Test func registerStoresPath() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "my-runner", installPath: "/opt/runners/my-runner")
    #expect(index.runnerIndex["my-runner"] == "/opt/runners/my-runner")
  }

  /// `register` called twice with the same name updates the path.
  @Test func registerOverwritesExistingEntry() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "runner-a", installPath: "/old/path")
    index.register(name: "runner-a", installPath: "/new/path")
    #expect(index.runnerIndex["runner-a"] == "/new/path")
  }

  /// Multiple runners can be registered independently.
  @Test func registerMultipleRunners() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "alpha", installPath: "/runners/alpha")
    index.register(name: "beta", installPath: "/runners/beta")
    #expect(index.runnerIndex.count == 2)
    #expect(index.runnerIndex["alpha"] == "/runners/alpha")
    #expect(index.runnerIndex["beta"] == "/runners/beta")
  }

  // MARK: - unregister

  /// `unregister` removes a previously registered runner.
  @Test func unregisterRemovesEntry() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "to-remove", installPath: "/path")
    index.unregister(name: "to-remove")
    #expect(index.runnerIndex["to-remove"] == nil)
  }

  /// `unregister` on an unknown name is a no-op (does not crash).
  @Test func unregisterUnknownNameIsNoop() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.unregister(name: "does-not-exist")
    #expect(index.runnerIndex.isEmpty)
  }

  /// `unregister` only removes the targeted runner, leaving others intact.
  @Test func unregisterLeavesOthersIntact() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "keep", installPath: "/keep")
    index.register(name: "remove", installPath: "/remove")
    index.unregister(name: "remove")
    #expect(index.runnerIndex["keep"] == "/keep")
    #expect(index.runnerIndex["remove"] == nil)
  }

  // MARK: - Persistence (UserDefaults round-trip)

  /// A new `LocalRunnerIndex` instance backed by the same suite reads back entries written
  /// by a previous instance, confirming that `persistIndex()` / `loadIndex()` round-trip correctly.
  @Test func persistenceRoundTrip() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    // Write via first instance
    let writer = LocalRunnerIndex(defaults: defaults)
    writer.register(name: "persistent-runner", installPath: "/persistent/path")

    // Read back via a fresh instance on the same suite
    let reader = LocalRunnerIndex(defaults: defaults)
    #expect(reader.runnerIndex["persistent-runner"] == "/persistent/path")
  }

  // MARK: - Edge cases

  /// Name lookup is case-sensitive: "Runner-A" and "runner-a" are distinct keys.
  /// Design decision: `runnerIndex` is a plain `[String: String]` dictionary, so key
  /// comparison uses Swift's default Unicode scalar equality (case-sensitive).
  /// This test exercises the full persist->read round-trip via `UserDefaults`, not just
  /// in-memory dictionary semantics, to guard against case-folding during serialisation.
  @Test func nameLookupIsCaseSensitive() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    let index = LocalRunnerIndex(defaults: defaults)
    index.register(name: "Runner-A", installPath: "/path/upper")
    // Lookup with different casing must NOT find the entry.
    #expect(index.runnerIndex["runner-a"] == nil)
    // Lookup with the exact original casing must find it.
    #expect(index.runnerIndex["Runner-A"] == "/path/upper")
  }
}
