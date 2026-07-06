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
/// `failureHookEnabled` defaults to `false`, matching the legacy
/// `UserDefaults.standard.bool(forKey:)` default for a missing key.
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

    /// Whether the failure hook is enabled for this scope.
    public var failureHookEnabled: Bool

    /// The shell command to run on failure. `nil` = use the default command.
    public var failureHookCommand: String?

    /// Local filesystem path to the repository for this scope. `nil` = not set.
    public var localRepoPath: String?

    /// Branch to restrict the failure hook to. `nil` = fire for all branches.
    public var failureHookBranch: String?

    // MARK: - Init

    /// Creates a `ScopePreferences` value.
    ///
    /// All parameters are optional with safe defaults so callers can construct
    /// a value specifying only the fields they care about.
    public init(
        alias: String? = nil,
        pollingInterval: Int? = nil,
        notifyOnSuccess: Bool? = nil,
        notifyOnFailure: Bool? = nil,
        failureHookEnabled: Bool = false,
        failureHookCommand: String? = nil,
        localRepoPath: String? = nil,
        failureHookBranch: String? = nil
    ) {
        self.alias = alias
        self.pollingInterval = pollingInterval
        self.notifyOnSuccess = notifyOnSuccess
        self.notifyOnFailure = notifyOnFailure
        self.failureHookEnabled = failureHookEnabled
        self.failureHookCommand = failureHookCommand
        self.localRepoPath = localRepoPath
        self.failureHookBranch = failureHookBranch
    }
}
