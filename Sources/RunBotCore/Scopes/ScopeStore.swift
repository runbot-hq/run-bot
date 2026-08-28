// ScopeStore.swift
// RunBotCore
import Foundation

// MARK: - ScopeStore

/// Persists the list of watched GitHub scopes as `[ScopeEntry]` in `UserDefaults`.
///
/// Mutations update the `@Observable` `entries` array; `RunnerStore` observes
/// `activeScopes` via `withObservationTracking`/`AsyncStream` (no Combine bridge).
@MainActor
@Observable
public final class ScopeStore {
  /// Shared singleton — single source of truth for all scope operations.
  public static let shared = ScopeStore()

  /// Shared `JSONDecoder` — reused across all `load()` calls instead of per-call instantiation.
  private let decoder = JSONDecoder()
  /// Shared `JSONEncoder` — reused across all `save()` calls instead of per-call instantiation.
  private let encoder = JSONEncoder()

  /// `UserDefaults` suite used for all reads and writes.
  /// Injected via `init(store:)` so tests can pass an ephemeral suite (P7).
  private let store: UserDefaults

  /// `UserDefaults` key for the JSON-encoded `[ScopeEntry]` array.
  private let entriesKey = "scopeEntries"

  /// All scope entries, persisted as JSON in `UserDefaults`.
  /// `private(set)` — mutate only through the designated methods on this type
  /// (`add(_:)`, `remove(id:)`, `setEnabled(_:_:)`). `load()` via `init()` is
  /// the only other write path; it assigns during initialisation only.
  public private(set) var entries: [ScopeEntry] = []

  /// Scopes that are currently enabled — used by `RunnerStore` for polling.
  public var activeScopes: [String] { entries.filter(\.isEnabled).map(\.scope) }

  /// Designated initialiser.
  ///
  /// - Parameter store: The `UserDefaults` suite to read from and write to.
  ///   Pass `.standard` in production (via the `shared` singleton) or an
  ///   ephemeral suite (`UserDefaults(suiteName:)`) in unit tests to avoid
  ///   polluting the real preferences database. (P7)
  public init(store: UserDefaults = .standard) {
    self.store = store
    entries = loadEntries()
  }

  // MARK: - Persistence

  /// Loads `[ScopeEntry]` from `UserDefaults`. Returns an empty array on decode failure.
  private func loadEntries() -> [ScopeEntry] {
    guard let data = store.data(forKey: entriesKey) else {
      log("ScopeStore › no stored entries found", category: .scope)
      return []
    }
    do {
      let decoded = try decoder.decode([ScopeEntry].self, from: data)
      log("ScopeStore › loaded \(decoded.count) scope entry(ies)", category: .scope)
      return decoded
    } catch {
      log("ScopeStore › decode error: \(error) — returning empty", category: .scope)
      return []
    }
  }

  /// JSON-encodes `newEntries` and writes them to `UserDefaults`.
  /// Logs an error and no-ops when encoding fails.
  /// - Parameter newEntries: The complete list of entries to persist.
  private func save(_ newEntries: [ScopeEntry]) {
    do {
      let data = try encoder.encode(newEntries)
      store.set(data, forKey: entriesKey)
      log("ScopeStore › saved \(newEntries.count) scope entry(ies)", category: .scope)
    } catch {
      log("ScopeStore › encode error: \(error)", category: .scope)
    }
  }

  /// Persists the current in-memory `entries` array to `UserDefaults`.
  private func persist() { save(entries) }

  // MARK: - Mutations

  /// Appends a new enabled entry after trimming whitespace and lowercasing.
  /// No-ops if `scope` is empty after trimming, or if an identical (lowercased)
  /// scope string already exists.
  ///
  /// Scope strings are lowercased at the point of entry so that `MyOrg/Repo`
  /// and `myorg/repo` are treated as the same scope. This is necessary because
  /// `ScopePreferencesStore` keys its `UserDefaults` blobs as
  /// `"scope.<scope>.preferences"` using the raw string verbatim — storing
  /// mixed-case variants would silently produce orphaned prefs keys and
  /// double-poll the same upstream GitHub scope.
  public func add(_ scope: String) {
    let trimmed = scope.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !trimmed.isEmpty, !entries.contains(where: { $0.scope == trimmed }) else { return }
    entries.append(ScopeEntry(scope: trimmed))
    persist()
    log("ScopeStore › added scope: \(trimmed)", category: .scope)
  }

  /// Removes the entry with the given ID. No-ops if not found.
  public func remove(id: UUID) {
    guard entries.contains(where: { $0.id == id }) else { return }
    entries.removeAll(where: { $0.id == id })
    persist()
    log("ScopeStore › removed scope id: \(id)", category: .scope)
  }

  /// Toggles the `isEnabled` flag for the entry with the given ID and persists
  /// the change. `RunnerStore` observes `activeScopes` via `withObservationTracking`,
  /// so replacing the element in the `@Observable` `entries` array triggers a
  /// poll-loop restart.
  public func setEnabled(_ id: UUID, _ enabled: Bool) {
    guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[idx] = entries[idx].copying(isEnabled: enabled)
    persist()
    // Log the committed value from the array, not the argument, so the log
    // remains accurate if copying(isEnabled:) ever gains filtering logic.
    log(
      "ScopeStore › scope \(entries[idx].scope) isEnabled=\(entries[idx].isEnabled)",
      category: .scope)
  }

  // MARK: - Display name cache

  /// Re-hydrates the transient `displayName` on every entry from `ScopePreferencesStore`.
  ///
  /// Call this once after launch (from `AppDelegate+StoreSetup`) and again after
  /// `ScopeEditSheet` saves new preferences, so `ScopesView` reflects alias changes
  /// without requiring a full restart. Runs on `@MainActor`; the actor hop to
  /// `ScopePreferencesStore` is handled by `preferences(for:)`.
  ///
  /// ## Concurrency safety
  /// Rather than capturing a pre-`await` snapshot of `entries` and writing it back
  /// wholesale (which would clobber concurrent `add`/`remove`/`setEnabled` mutations
  /// that occurred during the loop's `await` points), this method collects aliases
  /// into a `[UUID: String?]` map and merges them into the *current* `entries` array
  /// after all awaits complete. Entries added or removed during the loop are
  /// unaffected; only their `displayName` field is updated when found by ID.
  ///
  /// ## @Observable churn avoidance
  /// `ScopeEntry.Equatable` intentionally excludes `displayName` (it is transient,
  /// not persisted). An unconditional array reassignment would fire `@Observable`
  /// change notifications even when no alias actually changed, causing unnecessary
  /// SwiftUI re-renders. This method therefore only writes back entries whose
  /// `displayName` actually differs from the fetched alias.
  public func refreshDisplayNames() async {
    // Iterate the snapshot to know which scopes to fetch — but do NOT write
    // this snapshot back to `entries` after the awaits.
    let snapshot = entries
    var aliasByID: [UUID: String?] = [:]
    for entry in snapshot {
      let prefs = await ScopePreferencesStore.shared.preferences(for: entry.scope)
      let alias = prefs.alias.flatMap { raw in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
      }
      aliasByID[entry.id] = alias
    }
    // Merge into the *current* entries (not the pre-await snapshot) so that
    // any add/remove/setEnabled mutations that occurred during the awaits above
    // are preserved. Only write back an entry when its displayName actually
    // changed — avoids spurious @Observable notifications for unchanged aliases.
    var changed = false
    entries = entries.map { entry in
      guard let alias = aliasByID[entry.id] else { return entry }
      guard alias != entry.displayName else { return entry }
      changed = true
      return entry.copying(displayName: alias)
    }
    if changed {
      log("ScopeStore › refreshed display names for \(entries.count) scope(s)", category: .scope)
    } else {
      log(
        "ScopeStore › refreshDisplayNames: no display names changed, skipping write",
        category: .scope)
    }
  }
}
