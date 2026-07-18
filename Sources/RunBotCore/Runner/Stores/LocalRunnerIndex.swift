// LocalRunnerIndex.swift
// RunBotCore

import Foundation

// MARK: - LocalRunnerIndex

/// Owns the `UserDefaults`-backed name → install-path index for locally-registered runners.
///
/// Pure persistence layer with no knowledge of the runner model — easily unit-testable in isolation.
///
/// ## Why not `@MainActor`
/// `LocalRunnerIndex` is owned exclusively by the `LocalRunnerStore` actor, which provides
/// serial execution. `@MainActor` isolation would be both incorrect (the actor is not the main
/// actor) and unnecessary — all access is already serialised through `LocalRunnerStore`'s
/// executor. `UserDefaults` read/write of individual keys is documented thread-safe by Apple;
/// this class uses no KVO or `NotificationCenter` subscriptions on `UserDefaults`, so no
/// main-actor coordination is required. Contrast with `AppPreferencesStore` and
/// `NotificationPreferences`, which use `@AppStorage` (a SwiftUI property wrapper that requires
/// `@MainActor`) — `LocalRunnerIndex` stores plain `Data` blobs and does not use `@AppStorage`.
///
/// ## Why `final`
/// `final` prevents subclasses from shadowing the `decoder` / `encoder` stored properties or
/// the `loadIndex` / `persistIndex` helpers. The correctness invariant — that all reads and
/// writes share the same reused `JSONDecoder` / `JSONEncoder` instances under a single actor's
/// serialised execution — would be violated if a subclass re-declared those members. `final`
/// makes any such attempt a compile error. Test isolation is achieved via the `defaults`
/// constructor parameter, not subclassing.
///
/// ## Sendable / thread safety
/// `LocalRunnerIndex` is not `Sendable` and has no actor isolation. It is safe solely because
/// `LocalRunnerStore` owns the only reference and serialises every call through its executor.
/// If `LocalRunnerIndex` is ever referenced from outside `LocalRunnerStore`, the stored
/// `JSONDecoder` / `JSONEncoder` instances (which are not `Sendable`) would be a data race.
/// This is a pre-existing pattern mirroring `ScopePreferencesStore` (P17) — do not pass
/// a `LocalRunnerIndex` instance across actor boundaries.
///
/// Storage format: JSON-encoded `[String: String]` stored as `Data` under `indexKey`.
public final class LocalRunnerIndex {

    // MARK: - Storage key

    /// The `UserDefaults` key used to persist the runner name → install path index.
    private static let indexKey = "localRunnerIndex"

    // MARK: - State

    /// Maps runnerName → installPath, persisted to `UserDefaults`.
    ///
    /// ## Why `public private(set)`
    /// The getter is `public` because `LocalRunnerStore` — itself a `public` type —
    /// reads this property directly to answer queries about registered runners.
    /// `internal` would suffice within the module but `LocalRunnerStore` is a
    /// separate file in the same module and its callers (outside the module) drive
    /// a `public` API surface that ultimately reads through this property.
    /// The setter is `private` to enforce the invariant that all mutations go
    /// through `register(name:installPath:)` or `unregister(name:)`, which also
    /// call `persistIndex()` — preventing in-memory/UserDefaults divergence from
    /// a direct dictionary assignment.
    public private(set) var runnerIndex: [String: String] = [:]

    /// The `UserDefaults` store used for persistence. Defaults to `.standard`; injectable for tests.
    private let defaults: UserDefaults

    /// Reused `JSONDecoder` instance.
    ///
    /// Safe to reuse without synchronisation because all calls to `loadIndex()` and
    /// `persistIndex()` are serialised by `LocalRunnerStore`'s actor executor — the
    /// same pattern as `ScopePreferencesStore` (P17). See class-level ## Sendable /
    /// thread safety for the ownership contract.
    private let decoder = JSONDecoder()

    /// Reused `JSONEncoder` instance with `.sortedKeys` output formatting.
    ///
    /// `.sortedKeys` ensures deterministic byte output so that two `persistIndex()`
    /// calls with identical logical content produce identical `Data`, preventing
    /// spurious `UserDefaults` writes and the associated
    /// `NSUserDefaultsDidChangeNotification` churn.
    ///
    /// Safe to reuse without synchronisation — see `decoder` doc above and
    /// class-level ## Sendable / thread safety.
    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }()

    // MARK: - Init

    /// Initialises the index and loads the persisted entries from `UserDefaults`.
    ///
    /// ## Why this init never throws
    /// If stored `Data` exists but cannot be decoded, the error is logged and the
    /// index starts empty — preserving the invariant that `init` never throws.
    /// An empty index is always a safe starting state: callers will re-register
    /// runners on their next lifecycle event rather than the app crashing or
    /// failing to launch due to a malformed persisted blob.
    ///
    /// ## Why `defaults` has a default value of `.standard`
    /// The default value makes call sites in production code (which always want
    /// `.standard`) concise. Test targets pass an ephemeral suite to isolate
    /// reads and writes from the real preferences database. The parameter is
    /// `public` so test targets (separate modules) can construct isolated instances
    /// without requiring `@testable import` or `internal` access.
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
    ///
    /// On encode failure, logs the error and leaves the stored `UserDefaults` value
    /// unchanged. **User-visible consequence:** the in-memory `runnerIndex` will
    /// diverge from the persisted value until the next successful `persistIndex()`
    /// call — meaning a relaunch would load the last successfully-persisted state,
    /// which may be missing entries added since the failure. Encode failures are
    /// expected to be transient (e.g. memory pressure); the caller does not retry.
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
