// LocalRunnerIndexTests.swift
// RunBotCoreTests
import Foundation
import Testing

@testable import RunBotCore

// MARK: - LocalRunnerIndexTests

/// Single persistence-lifecycle contract for `LocalRunnerIndex`, the
/// `UserDefaults`-backed name -> install-path store.
///
/// One ephemeral UUID-namespaced defaults suite proves the whole lifecycle:
/// registration persists, re-registering a name overwrites its path, runners
/// stay isolated, unregister removes only the requested runner, and a fresh
/// instance reloads the persisted result. Dictionary-only semantics (unknown
/// keys, repeated reads, empty state) carry no regression value and are not tested.
@Suite("LocalRunnerIndex")
struct LocalRunnerIndexTests {

  // MARK: - Helpers

  /// Returns a fresh, UUID-namespaced `UserDefaults` suite and its suite name.
  /// Callers are responsible for cleanup via `UserDefaults.standard.removePersistentDomain(forName:)`.
  private static func makeSuite() -> (UserDefaults, String) {
    let suiteName = "com.runbot.tests.LocalRunnerIndex.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    return (defaults, suiteName)
  }

  // MARK: - Lifecycle

  /// Register -> overwrite -> targeted unregister -> reload across instances.
  @Test func registrationPersistenceLifecycle() {
    let (defaults, suite) = Self.makeSuite()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    let index = LocalRunnerIndex(defaults: defaults)

    index.register(name: "runner-a", installPath: "/old/path")
    index.register(name: "runner-b", installPath: "/runner-b")

    // Re-registering a name overwrites its path; the other runner is untouched.
    index.register(name: "runner-a", installPath: "/new/path")

    index.unregister(name: "runner-b")

    #expect(index.runnerIndex == ["runner-a": "/new/path"])

    // A new instance backed by the same suite reloads the persisted result.
    let restored = LocalRunnerIndex(defaults: defaults)
    #expect(restored.runnerIndex == ["runner-a": "/new/path"])
  }
}
