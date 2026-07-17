// LocalRunnerIndex.swift
// RunBotCore

import Foundation

// MARK: - LocalRunnerIndex

/// Owns the `UserDefaults`-backed name → install-path index for locally-registered runners.
///
/// Pure persistence layer with no knowledge of the runner model — easily unit-testable in isolation.
/// Non-isolated: owned exclusively by the `LocalRunnerStore` actor, which serializes all access.
/// `UserDefaults` read/write of individual keys is thread-safe; this class uses no KVO or
/// change notifications on `UserDefaults`, so no main-actor coordination is required.
///
/// Storage format: JSON-encoded `[String: String]` stored as `Data` under `indexKey`.
public final class LocalRunnerIndex {

    // MARK: - Storage key

    /// The `UserDefaults` key used to persist the runner name → install path index.
    private static let indexKey = "localRunnerIndex"

    // MARK: - State

    /// Maps runnerName → installPath, persisted to `UserDefaults`.
    public private(set) var runnerIndex: [String: String] = [:]

    // MARK: - Init

    /// The `UserDefaults` store used for persistence. Defaults to `.standard`; injectable for tests.
    private let defaults: UserDefaults

    /// Reused decoder. Only ever called from `LocalRunnerStore`'s serial actor executor,
    /// so there is no concurrent access — matching the pattern in `ScopePreferencesStore` (P17).
    private let decoder = JSONDecoder()

    /// Reused encoder. Only ever called from `LocalRunnerStore`'s serial actor executor,
    /// so there is no concurrent access — matching the pattern in `ScopePreferencesStore` (P17).
    private let encoder = JSONEncoder()

    /// Initialises the index and loads the persisted entries from `UserDefaults`.
    /// If stored `Data` exists but cannot be decoded, the error is logged and the
    /// index starts empty — preserving the invariant that `init` never throws.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadIndex()
    }

    // MARK: - Mutations

    /// Adds or updates the index entry for `name`, mapping it to `installPath`, then persists.
    public func register(name: String, installPath: String) {
        log("LocalRunnerIndex › register — '\(name)' at \(installPath) (was: \(String(describing: runnerIndex[name])))", category: .runner)
        runnerIndex[name] = installPath
        persistIndex()
    }

    /// Removes `name` from the persisted index.
    public func unregister(name: String) {
        log("LocalRunnerIndex › unregister '\(name)'", category: .runner)
        runnerIndex.removeValue(forKey: name)
        persistIndex()
    }

    // MARK: - Private helpers

    /// Hydrates `runnerIndex` from `UserDefaults` at init time.
    ///
    /// Decode order:
    /// 1. `Data` key present → JSON-decode as `[String: String]`.
    ///    On `DecodingError`, logs and falls through to empty so malformed data
    ///    is surfaced in logs without crashing or losing other entries.
    /// 2. Key absent → start with empty index.
    private func loadIndex() {
        if let data = defaults.data(forKey: Self.indexKey) {
            do {
                runnerIndex = try decoder.decode([String: String].self, from: data)
                log("LocalRunnerIndex › loadIndex — \(runnerIndex.count) entry(ies): \(runnerIndex.keys.sorted())", category: .runner)
            } catch {
                log("LocalRunnerIndex › loadIndex — JSON decode failed: \(error). Starting with empty index.", category: .runner)
                runnerIndex = [:]
            }
        } else {
            runnerIndex = [:]
            log("LocalRunnerIndex › loadIndex — no data found, starting empty", category: .runner)
        }
    }

    /// JSON-encodes and writes the current `runnerIndex` to `UserDefaults`.
    /// On encode failure, logs the error and leaves the stored value unchanged.
    private func persistIndex() {
        do {
            let data = try encoder.encode(runnerIndex)
            defaults.set(data, forKey: Self.indexKey)
            log("LocalRunnerIndex › persistIndex — \(runnerIndex.count) entry(ies) written", category: .runner)
        } catch {
            log("LocalRunnerIndex › persistIndex — encode failed: \(error)", category: .runner)
        }
    }
}
