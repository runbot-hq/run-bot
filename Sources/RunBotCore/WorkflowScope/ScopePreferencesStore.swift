// ScopePreferencesStore.swift
// RunBotCore
import Foundation

// MARK: - ScopePreferencesStore

/// Actor that owns all `UserDefaults` read/write for per-scope preferences.
///
/// Preferences are serialised as a single `ScopePreferences` JSON blob per scope
/// under the key `scope.<scope>.preferences`.
///
/// ## Why one blob per scope?
/// A single JSON blob means `cleanUp(scope:)` removes the blob key *and* any
/// surviving legacy flat keys in one call. Adding a new field to `ScopePreferences`
/// automatically includes it in cleanup without touching this file.
///
/// ## Encoder/decoder (P17)
/// `decoder` and `encoder` are plain `private let` stored properties — not `nonisolated`.
/// They are only ever called from actor-isolated `read` and `write`, which are serialised
/// by the actor's executor, so there is no concurrent access. Dropping `nonisolated`
/// removes any theoretical exposure to non-isolated call sites and avoids relying on
/// the undocumented thread-safety of `JSONDecoder`/`JSONEncoder`.
///
/// ## Individual setters vs modifyPreferences (P10)
/// The individual `setXxx` methods are retained for call sites that update a single
/// field in isolation. Each performs a full read-modify-write, which is correct
/// (the actor serialises them) but costs one extra decode + encode compared with a
/// single `modifyPreferences` call. **Prefer `modifyPreferences(for:with:)` whenever
/// two or more fields need to be updated together** — it performs the full RMW in one
/// actor hop, eliminating any TOCTOU window between a `preferences(for:)` read and a
/// subsequent `setPreferences(_:for:)` write. (P10)
///
/// ## P21 note
/// `JSONEncoder.outputFormatting` is intentionally NOT set to `.prettyPrinted`/`.sortedKeys`
/// here. P21 applies to agent-managed config files that are diffed in git between RunBot
/// and the GitHub Actions runner agent. `UserDefaults` blobs are opaque binary plist data
/// and are never inspected as text, so human-readable formatting is not applicable.
public actor ScopePreferencesStore: ScopePreferencesStoreProtocol {

  // MARK: - Shared instance

  /// The shared singleton — use this in production; pass `init(store:)` in tests.
  public static let shared = ScopePreferencesStore()

  // MARK: - Private state

  /// `UserDefaults` instance backing all reads and writes.
  private let store: UserDefaults

  /// Reused decoder. Private (not nonisolated) — only called from actor-isolated
  /// `read(_:)`, so the actor's serial executor prevents concurrent access. (P17)
  private let decoder = JSONDecoder()
  /// Reused encoder. Private (not nonisolated) — only called from actor-isolated
  /// `write(_:for:)`, so the actor's serial executor prevents concurrent access. (P17)
  private let encoder = JSONEncoder()

  // MARK: - Legacy flat-key field list

  /// The complete set of flat-key suffixes used by the pre-migration scheme.
  ///
  /// Kept as a single source of truth so `cleanUp` can remove any orphaned
  /// legacy flat keys left over from installs that ran before the migration.
  /// If a new field is ever added here it will automatically be cleaned up.
  private static let legacyFields = [
    "alias", "pollingInterval", "notifyOnSuccess", "notifyOnFailure",
    "failureHookEnabled", "failureHookCommand", "localRepoPath", "failureHookBranch",
  ]

  // MARK: - Init

  /// Creates a store backed by `store`.
  /// - Parameter store: `UserDefaults` instance to read/write. Defaults to `.standard`;
  ///   pass a suite instance in tests to avoid polluting real defaults. (P7, P3)
  public init(store: UserDefaults = .standard) {
    self.store = store
  }

  // MARK: - Key helpers

  /// Returns the `UserDefaults` key used to store the JSON blob for `scope`.
  private func blobKey(for scope: String) -> String {
    "scope.\(scope).preferences"
  }

  // MARK: - Internal read/write

  /// Reads the stored `ScopePreferences` for `scope`, returning defaults if absent or undecodable.
  private func read(scope: String) -> ScopePreferences {
    guard
      let data = store.data(forKey: blobKey(for: scope)),
      let prefs = try? decoder.decode(ScopePreferences.self, from: data)
    else { return ScopePreferences() }
    return prefs
  }

  /// Encodes and writes `prefs` for `scope`.
  ///
  /// `JSONEncoder` encoding a flat `Codable` struct of `String?/Bool/Int?` fields
  /// cannot realistically fail. If it ever does (e.g. OOM), the failure is logged
  /// and the write is a no-op — the stored blob simply retains its previous value.
  /// `throws` is intentionally absent: surfacing an error here would require
  /// changing all `setXxx` protocol signatures to `throws` with no practical benefit.
  private func write(_ prefs: ScopePreferences, for scope: String) {
    guard let data = try? encoder.encode(prefs) else {
      log(
        "ScopePreferencesStore › encode failed for scope: \(scope) — write skipped",
        category: .scope)
      return
    }
    store.set(data, forKey: blobKey(for: scope))
    log("ScopePreferencesStore › saved preferences for \(scope)", category: .scope)
  }

  // MARK: - ScopePreferencesStoreProtocol — bulk snapshot / write

  /// Returns the full `ScopePreferences` snapshot for `scope` in a single actor hop.
  ///
  /// This is the preferred read path when multiple fields are needed at once
  /// (e.g. seeding `ScopeEditSheet` draft state). One `await` instead of N.
  public func preferences(for scope: String) -> ScopePreferences {
    read(scope: scope)
  }

  /// Writes a complete `ScopePreferences` snapshot for `scope` in a single actor hop.
  ///
  /// This is the preferred write path when multiple fields need to be committed
  /// atomically (e.g. `ScopeEditSheet.confirmSave()`). One `await` and one
  /// encode/write instead of N sequential read-modify-write cycles.
  ///
  /// - Important: Do not call `preferences(for:)` and then `setPreferences(_:for:)`
  ///   as two separate `await` calls — that is a TOCTOU pattern (P10). Use
  ///   `modifyPreferences(for:with:)` instead when you need to read-then-write.
  public func setPreferences(_ prefs: ScopePreferences, for scope: String) {
    write(prefs, for: scope)
  }

  // MARK: - ScopePreferencesStoreProtocol — alias

  /// Returns the alias for `scope`, or `nil` if none is set.
  ///
  /// - Note: For single-field updates prefer this setter. For multi-field
  ///   updates use `modifyPreferences(for:with:)` to avoid redundant
  ///   encode/decode round-trips. (P10)
  public func alias(for scope: String) -> String? {
    read(scope: scope).alias.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Sets the display alias for `scope`, trimming whitespace. Passing `nil` or blank clears the alias.
  public func setAlias(_ alias: String?, for scope: String) {
    var prefs = read(scope: scope)
    let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
    prefs.alias = (trimmed?.isEmpty == false) ? trimmed : nil
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › alias for \(scope) = \(prefs.alias ?? "nil (cleared)")",
      category: .scope)
  }

  /// Returns the alias for `scope` if set, otherwise the raw scope string.
  public func displayName(for scope: String) -> String {
    alias(for: scope) ?? scope
  }

  // MARK: - ScopePreferencesStoreProtocol — polling interval

  /// - Note: For single-field updates prefer this setter. For multi-field
  ///   updates use `modifyPreferences(for:with:)` to avoid redundant
  ///   encode/decode round-trips. (P10)
  public func pollingInterval(for scope: String) -> Int? {
    read(scope: scope).pollingInterval
  }

  /// Sets the per-scope polling interval in seconds. Pass `nil` to fall back to the global default.
  public func setPollingInterval(_ interval: Int?, for scope: String) {
    var prefs = read(scope: scope)
    prefs.pollingInterval = interval
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › pollingInterval for \(scope) = \(interval.map(String.init) ?? "nil (use global)")",
      category: .scope)
  }

  // MARK: - ScopePreferencesStoreProtocol — notification overrides

  /// - Note: For single-field updates prefer this setter. For multi-field
  ///   updates use `modifyPreferences(for:with:)` to avoid redundant
  ///   encode/decode round-trips. (P10)
  public func notifyOnSuccess(for scope: String) -> Bool? {
    read(scope: scope).notifyOnSuccess
  }

  /// Sets the per-scope success-notification override. Pass `nil` to use the global setting.
  public func setNotifyOnSuccess(_ value: Bool?, for scope: String) {
    var prefs = read(scope: scope)
    prefs.notifyOnSuccess = value
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › notifyOnSuccess for \(scope) = \(value.map(String.init) ?? "nil (use global)")",
      category: .scope)
  }

  /// - Note: For single-field updates prefer this setter. For multi-field
  ///   updates use `modifyPreferences(for:with:)` to avoid redundant
  ///   encode/decode round-trips. (P10)
  public func notifyOnFailure(for scope: String) -> Bool? {
    read(scope: scope).notifyOnFailure
  }

  /// Sets the per-scope failure-notification override. Pass `nil` to use the global setting.
  public func setNotifyOnFailure(_ value: Bool?, for scope: String) {
    var prefs = read(scope: scope)
    prefs.notifyOnFailure = value
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › notifyOnFailure for \(scope) = \(value.map(String.init) ?? "nil (use global)")",
      category: .scope)
  }

  // MARK: - ScopePreferencesStoreProtocol — failure hook

  /// - Note: For single-field updates prefer this setter. For multi-field
  ///   updates use `modifyPreferences(for:with:)` to avoid redundant
  ///   encode/decode round-trips. (P10)
  public func failureHookEnabled(for scope: String) -> Bool {
    read(scope: scope).failureHookEnabled
  }

  /// Enables or disables the failure hook for `scope`.
  public func setFailureHookEnabled(_ enabled: Bool, for scope: String) {
    var prefs = read(scope: scope)
    prefs.failureHookEnabled = enabled
    write(prefs, for: scope)
    log("ScopePreferencesStore › failureHookEnabled for \(scope) = \(enabled)", category: .scope)
  }

  /// Returns the failure hook shell command for `scope`, or `nil` if unset or blank.
  public func failureHookCommand(for scope: String) -> String? {
    read(scope: scope).failureHookCommand.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Sets the failure hook shell command for `scope`, trimming whitespace. Passing `nil` or blank clears it.
  public func setFailureHookCommand(_ command: String?, for scope: String) {
    var prefs = read(scope: scope)
    let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
    prefs.failureHookCommand = (trimmed?.isEmpty == false) ? trimmed : nil
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › failureHookCommand for \(scope) = \(prefs.failureHookCommand ?? "nil (cleared)")",
      category: .scope)
  }

  /// Returns the local repository path for `scope`, or `nil` if unset or blank.
  public func localRepoPath(for scope: String) -> String? {
    read(scope: scope).localRepoPath.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Sets the local repository path for `scope`, trimming whitespace. Passing `nil` or blank clears it.
  public func setLocalRepoPath(_ path: String?, for scope: String) {
    var prefs = read(scope: scope)
    let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    prefs.localRepoPath = (trimmed?.isEmpty == false) ? trimmed : nil
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › localRepoPath for \(scope) = \(prefs.localRepoPath ?? "nil (cleared)")",
      category: .scope)
  }

  /// Returns the failure hook branch filter for `scope`, or `nil` if unset (runs on all branches).
  public func failureHookBranch(for scope: String) -> String? {
    read(scope: scope).failureHookBranch.flatMap { $0.isEmpty ? nil : $0 }
  }

  /// Sets the failure hook branch filter for `scope`, trimming whitespace.
  /// Pass `nil` or blank to run on all branches.
  public func setFailureHookBranch(_ branch: String?, for scope: String) {
    var prefs = read(scope: scope)
    let trimmed = branch?.trimmingCharacters(in: .whitespacesAndNewlines)
    prefs.failureHookBranch = (trimmed?.isEmpty == false) ? trimmed : nil
    write(prefs, for: scope)
    log(
      "ScopePreferencesStore › failureHookBranch for \(scope) = \(prefs.failureHookBranch ?? "nil (all branches)")",
      category: .scope)
  }

  // MARK: - ScopePreferencesStoreProtocol — cleanup

  /// Removes all persisted data for `scope`: the blob key and any surviving
  /// legacy flat keys.
  ///
  /// The legacy flat-key removal handles the edge case where a scope existed in the
  /// old flat-key format but was removed from `ScopeStore` before migration completed —
  /// those keys would otherwise be orphaned indefinitely in `UserDefaults`.
  /// For post-migration scopes the flat-key removals are no-ops.
  ///
  /// - Important: Always `await cleanUp(scope:)` **before** calling
  ///   `ScopeStore.remove(id:)`. `ScopeStore.remove` restarts the poll loop
  ///   immediately; if cleanup has not completed by then, the next poll tick
  ///   may read a stale preferences blob for the removed scope. (#1538)
  public func cleanUp(scope: String) {
    store.removeObject(forKey: blobKey(for: scope))
    for field in Self.legacyFields {
      store.removeObject(forKey: "scope.\(scope).\(field)")
    }
    log("ScopePreferencesStore › cleaned up all keys for scope: \(scope)", category: .scope)
  }
}
