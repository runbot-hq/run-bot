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
    /// This property is intentionally UI/persistence-only in this PR. No
    /// notification-dispatch callsite reads it yet — that wiring is tracked
    /// in #2070 and will be added in a follow-up PR. The picker is functional
    /// (writes correctly to UserDefaults) but the setting has no runtime effect
    /// until dispatch is wired. This is not a bug introduced here.
    ///
    /// ## Orphaned UserDefaults keys
    /// The previous `notifications.notifyOnSuccess` and `notifications.notifyOnFailure`
    /// keys are intentionally left in UserDefaults without cleanup. The app has
    /// zero users in the wild, so no migration path is needed. The dead keys are
    /// harmless and will simply be ignored.
    // TODO: wire notification dispatch to read this value — #2070
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
        let rawMode = store.string(forKey: Key.notificationMode) ?? NotificationMode.all.rawValue
        notificationMode = NotificationMode(rawValue: rawMode) ?? .all
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
    public static func register(into store: UserDefaults) {
        store.register(defaults: [
            Key.notificationMode: NotificationMode.all.rawValue,
        ])
    }
}
