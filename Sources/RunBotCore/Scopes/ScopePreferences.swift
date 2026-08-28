// ScopePreferences.swift
// RunBotCore
import Foundation

// MARK: - ScopePreferences

/// Typed, `Codable` snapshot of all per-scope user preferences.
///
/// Serialised as a single JSON blob under the key `scope.<scope>.preferences`
/// in `UserDefaults`. Using one blob per scope means `cleanUp(scope:)` is a
/// single `removeObject(forKey:)` call — no hardcoded field list to keep in sync.
///
/// All fields are optional (or have safe defaults) so that a missing key in the
/// stored JSON decodes cleanly with no migration needed for future additions.
public struct ScopePreferences: Codable, Equatable, Sendable {

    // MARK: - Fields

    /// Human-readable alias for the scope. `nil` = display raw scope string.
    public var alias: String?

    /// Per-scope polling interval override in seconds. `nil` = use global setting.
    public var pollingInterval: Int?

    /// Per-scope notify-on-success override. `nil` = use global setting.
    public var notifyOnSuccess: Bool?

    /// Per-scope notify-on-failure override. `nil` = use global setting.
    public var notifyOnFailure: Bool?

    // MARK: - Init

    /// Creates a `ScopePreferences` value.
    ///
    /// All parameters are optional with safe defaults so callers can construct
    /// a value specifying only the fields they care about.
    public init(
        alias: String? = nil,
        pollingInterval: Int? = nil,
        notifyOnSuccess: Bool? = nil,
        notifyOnFailure: Bool? = nil
    ) {
        self.alias = alias
        self.pollingInterval = pollingInterval
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
    }
}
