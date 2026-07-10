// ScopePreferencesStoreProtocol.swift
// RunBotCore
import Foundation

// MARK: - ScopePreferencesStoreProtocol

/// Full read/write interface for per-scope `UserDefaults` preferences.
///
/// Constrained to `Actor` (which implies `Sendable`) so every call site is
/// visibly `async` — making actor crossings explicit and compiler-enforced (P4).
public protocol ScopePreferencesStoreProtocol: Actor {

    // MARK: - Bulk snapshot / write

    /// Returns a full `ScopePreferences` snapshot for the scope in one actor hop.
    ///
    /// Prefer this over calling individual getters in sequence when multiple fields
    /// are needed at once (e.g. before presenting `ScopeEditSheet`) — one `await`
    /// instead of N. The returned value is a value-type copy and is safe to use
    /// outside the actor.
    func preferences(for scope: String) -> ScopePreferences

    /// Writes a complete `ScopePreferences` snapshot for the scope in one actor hop.
    ///
    /// Prefer this over calling multiple individual setters in sequence (e.g. in
    /// `confirmSave()`) — one `await` and one encode/write instead of N.
    func setPreferences(_ prefs: ScopePreferences, for scope: String)

    /// Reads, mutates, and writes the `ScopePreferences` for `scope` atomically
    /// within a single actor hop.
    ///
    /// Use this instead of a separate `preferences(for:)` + `setPreferences(_:for:)`
    /// pair when you need to mutate a subset of fields while preserving the rest.
    func modifyPreferences(for scope: String, with mutation: @Sendable (inout ScopePreferences) -> Void)

    // MARK: - Alias

    /// Human-readable alias for the scope. `nil` = display raw scope string.
    func alias(for scope: String) -> String?
    /// Sets (or clears) the human-readable alias for the scope.
    func setAlias(_ alias: String?, for scope: String)
    /// Display name: alias if set, otherwise the raw scope string.
    func displayName(for scope: String) -> String

    // MARK: - Polling interval

    /// Per-scope polling interval override in seconds. `nil` = use global setting.
    func pollingInterval(for scope: String) -> Int?
    /// Sets (or clears) the per-scope polling interval override.
    func setPollingInterval(_ interval: Int?, for scope: String)

    // MARK: - Notification overrides

    /// Per-scope notify-on-success override. `nil` = use global.
    func notifyOnSuccess(for scope: String) -> Bool?
    /// Sets (or clears) the per-scope notify-on-success override.
    func setNotifyOnSuccess(_ value: Bool?, for scope: String)
    /// Per-scope notify-on-failure override. `nil` = use global.
    func notifyOnFailure(for scope: String) -> Bool?
    /// Sets (or clears) the per-scope notify-on-failure override.
    func setNotifyOnFailure(_ value: Bool?, for scope: String)

    // MARK: - Cleanup

    /// Removes all persisted preferences for the scope.
    /// Call from `ScopeStore.remove(id:)` to avoid orphaned data accumulating.
    func cleanUp(scope: String)
}

// MARK: - Default implementations

/// Default implementation of `modifyPreferences` — performs a full read-modify-write
/// inside the actor in a single hop. Concrete conformers can override if needed.
public extension ScopePreferencesStoreProtocol {
    /// Reads, applies `mutation`, and writes — all inside the actor in a single hop.
    func modifyPreferences(for scope: String, with mutation: @Sendable (inout ScopePreferences) -> Void) {
        var prefs = preferences(for: scope)
        mutation(&prefs)
        setPreferences(prefs, for: scope)
    }
}
