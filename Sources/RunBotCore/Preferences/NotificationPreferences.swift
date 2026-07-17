// NotificationPreferences.swift
// RunBotCore
import Foundation
import Observation
import SwiftUI

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
/// `@AppStorage` handles the register-read-write lifecycle for the production
/// path (`.standard`). When a non-standard suite is injected via `init(store:)`,
/// the `@AppStorage` property is re-pointed to that suite so unit tests can
/// supply an ephemeral suite without polluting the real preferences database.
///
/// ## Orphaned UserDefaults keys
/// The previous `notifications.notifyOnSuccess` and `notifications.notifyOnFailure`
/// keys are intentionally left in UserDefaults without cleanup. The app has
/// zero users in the wild, so no migration path is needed. The dead keys are
/// harmless and will simply be ignored.
@MainActor
@Observable
public final class NotificationPreferences {
    /// Shared singleton — use this instead of calling `init(store:)` directly in
    /// production code. The convenience `init()` is `private` so the singleton is
    /// the only zero-argument construction path outside this file.
    public static let shared = NotificationPreferences()

    // MARK: - Preferences

    /// Unified notification mode replacing the two separate Bool flags.
    /// Persisted as a `String` rawValue in UserDefaults.
    ///
    /// Default changed from `.all` to `.never` in #2082 — opt-in is the better
    /// default for a notification preference; users who want alerts can enable them.
    ///
    /// ## Dispatch wiring
    /// Wired in #2070. Call `shouldNotify(conclusion:)` at every
    /// `UNUserNotificationCenter` dispatch site to gate notifications by this
    /// preference.
    @ObservationIgnored
    @AppStorage("notifications.notificationMode")
    public var _notificationModeRaw: String = NotificationMode.never.rawValue

    /// Typed accessor for `notificationMode`.
    ///
    /// Writing this property updates `_notificationModeRaw` (and therefore
    /// UserDefaults) atomically. Unrecognised raw values fall back to `.never`
    /// (e.g. after a downgrade that removes a previously persisted case).
    public var notificationMode: NotificationMode {
        get { NotificationMode(rawValue: _notificationModeRaw) ?? .never }
        set { _notificationModeRaw = newValue.rawValue }
    }

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    ///
    /// `private` by design — forces all production code through the `shared` singleton.
    /// Tests and Previews that need a fresh instance use `init(store:)` directly.
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
    /// ## Why `public`
    /// `public` is required for test-target injection (P7) — test targets are
    /// separate modules and cannot access `internal` members. This is intentional
    /// and not an oversight. The `private convenience init()` ensures zero-argument
    /// construction outside this file still routes through `shared`.
    ///
    /// ## `@MainActor` safety
    /// `@MainActor` isolation is enforced by the class declaration, not by the
    /// caller. Constructing this type off the main actor is a compiler error —
    /// the caller must be `@MainActor` or use `await MainActor.run { ... }`.
    /// There is no race hazard from making `init(store:)` public.
    public init(store: UserDefaults) {
        if store !== UserDefaults.standard {
            let raw = store.string(forKey: "notifications.notificationMode")
                ?? NotificationMode.never.rawValue
            __notificationModeRaw = AppStorage(
                wrappedValue: raw,
                "notifications.notificationMode",
                store: store
            )
        }
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
