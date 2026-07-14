// NotificationPreferences.swift
// RunBotCore
import Foundation
import Observation

// MARK: - NotificationMode

/// The set of workflow-result events for which RunBot sends notifications.
public enum NotificationMode: String, CaseIterable, Sendable {
    /// Notify for both successes and failures.
    case all
    /// Notify only when a job fails.
    case failuresOnly
    /// Notify only when a job succeeds.
    case successesOnly
    /// Never send notifications.
    case never

    /// Human-readable label shown in the Settings picker.
    public var label: String {
        switch self {
        case .all:           return "All"
        case .failuresOnly:  return "Failures only"
        case .successesOnly: return "Successes only"
        case .never:         return "Never"
        }
    }
}

// MARK: - NotificationPreferences

/// Persists notification preferences to UserDefaults.
///
/// ## Dependency injection (P7)
/// The `didSet` observers write to the injected `defaults` instance rather than
/// directly to `UserDefaults.standard`, matching the pattern in `AppPreferencesStore`
/// so that unit tests can supply an ephemeral suite without polluting the real
/// preferences database.
@MainActor
@Observable
public final class NotificationPreferences {
    /// Shared singleton — use this instead of calling init directly.
    public static let shared = NotificationPreferences()

    /// UserDefaults key constants.
    private enum Key {
        /// Key for the notification mode enum.
        static let notificationMode = "notifications.notificationMode"
    }

    // MARK: - Backing store

    /// The `UserDefaults` instance used for all reads and writes.
    /// Injected at init; defaults to `.standard` in production.
    private let defaults: UserDefaults

    // MARK: - Preferences

    /// Unified notification mode replacing the two separate Bool flags.
    /// Persisted as a `String` rawValue in UserDefaults.
    ///
    /// ## Dispatch wiring
    /// Wired in #2070. Call `shouldNotify(conclusion:)` at every
    /// `UNUserNotificationCenter` dispatch site to gate notifications by this
    /// preference.
    ///
    /// ## Orphaned UserDefaults keys
    /// The previous `notifications.notifyOnSuccess` and `notifications.notifyOnFailure`
    /// keys are intentionally left in UserDefaults without cleanup. The app has
    /// zero users in the wild, so no migration path is needed. The dead keys are
    /// harmless and will simply be ignored.
    public var notificationMode: NotificationMode {
        didSet {
            defaults.set(notificationMode.rawValue, forKey: Key.notificationMode)
        }
    }

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    private convenience init() {
        self.init(store: .standard)
    }

    /// Designated initialiser.
    ///
    /// - Parameter store: The `UserDefaults` suite to read from and write to.
    ///   Pass `.standard` in production (via the `shared` singleton) or an
    ///   ephemeral suite (`UserDefaults(suiteName:)`) in unit tests to avoid
    ///   polluting the real preferences database. (P7)
    ///
    /// Calls `register(into: store)` automatically — no need to call it
    /// separately in production code.
    public init(store: UserDefaults) {
        self.defaults = store
        NotificationPreferences.register(into: store)
        let rawMode = store.string(forKey: Key.notificationMode) ?? NotificationMode.never.rawValue
        notificationMode = NotificationMode(rawValue: rawMode) ?? .never
    }

    // MARK: - Registration

    /// Registers factory defaults so that `bool(forKey:)` returns the intended
    /// value on first launch without requiring an `object(forKey:) == nil` guard.
    ///
    /// `init(store:)` calls this automatically in production. This method is
    /// `public` for test setup only — call it when you need defaults registered
    /// before `init` runs (e.g. testing code that reads from `UserDefaults`
    /// directly before constructing a `NotificationPreferences` instance).
    ///
    /// - Parameter store: The `UserDefaults` instance to register defaults into.
    ///   Pass `.standard` for production; pass a suite instance in tests.
    ///
    /// Default changed from `.all` to `.never` in #2082 — opt-in is the better
    /// default for a notification preference; users who want alerts can enable them.
    public static func register(into store: UserDefaults) {
        store.register(defaults: [
            Key.notificationMode: NotificationMode.never.rawValue,
        ])
    }
}

// MARK: - Dispatch gating

/// Gating methods for `NotificationMode` — call `shouldNotify(conclusion:)` before
/// scheduling a `UNNotificationRequest`.
public extension NotificationPreferences {
    /// Returns `true` if a notification should be sent for the given job conclusion.
    ///
    /// Gating rules per mode:
    /// - `.failuresOnly` uses `conclusion.isFailure` (includes `.timedOut`,
    ///   `.startupFailure`, `.actionRequired` alongside `.failure`).
    /// - `.successesOnly` uses `conclusion == .success` (not `!isFailure`) — only
    ///   an explicit `.success` passes; `.neutral`, `.skipped`, `.cancelled` etc.
    ///   are excluded from this mode.
    /// - `.all` passes everything (including `.neutral` from a nil fallback).
    /// - `.never` passes nothing.
    ///
    /// Call this at every `UNUserNotificationCenter` dispatch site before
    /// scheduling a notification request:
    ///
    /// ```swift
    /// // When already on the @MainActor:
    /// if NotificationPreferences.shared.shouldNotify(conclusion: .success) {
    ///     scheduleNotification(for: job)
    /// }
    /// // When crossing from a non-main actor, use await MainActor.run:
    /// let shouldFire = await MainActor.run { prefs.shouldNotify(conclusion: conclusion) }
    /// ```
    ///
    /// - Parameter conclusion: The `JobConclusion` of the completed job.
    /// - Returns: Whether the current `notificationMode` permits sending a
    ///   notification for this outcome.
    func shouldNotify(conclusion: JobConclusion) -> Bool {
        switch notificationMode {
        case .all:           return true
        case .failuresOnly:  return conclusion.isFailure // not == .failure; includes .timedOut, .startupFailure, .actionRequired
        case .successesOnly: return conclusion == .success
        case .never:         return false
        }
    }
}
