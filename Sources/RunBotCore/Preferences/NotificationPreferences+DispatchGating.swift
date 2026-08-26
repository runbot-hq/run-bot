// NotificationPreferences+DispatchGating.swift
// RunBotCore

// MARK: - Dispatch gating

/// Gating methods for `NotificationMode` — call `shouldNotify(conclusion:)` before
/// scheduling a `UNNotificationRequest`.
///
/// ## Why a `public extension` rather than methods on the main type body
/// Grouping dispatch-gating logic in a separate extension — rather than
/// interleaving it with persistence declarations — makes the file scannable:
/// the main body covers storage, keys, init, and registration; this extension
/// covers all callsite-facing query logic. The `public` on the extension block
/// is an access-level default for the members it contains, not a deliberate
/// split of the type's interface. All members here are `public` by extension
/// inheritance and could equivalently live in the main body without any
/// behaviour change.
public extension NotificationPreferences {
    /// Returns `true` if a notification should be sent for the given job conclusion.
    ///
    /// Gating rules per mode:
    /// - `.failuresOnly` — uses `conclusion.isFailure` which includes `.timedOut`,
    ///   `.startupFailure`, `.actionRequired` alongside `.failure`. Not `== .failure`.
    /// - `.successesOnly` — uses `conclusion == .success` only; `.neutral`,
    ///   `.skipped`, `.cancelled` etc. do not pass this mode.
    /// - `.all` — passes everything.
    /// - `.never` — passes nothing.
    ///
    /// ```swift
    /// // On @MainActor:
    /// if NotificationPreferences.shared.shouldNotify(conclusion: .success) {
    ///     scheduleNotification(for: job)
    /// }
    /// // From a non-main actor:
    /// let shouldFire = await MainActor.run { prefs.shouldNotify(conclusion: conclusion) }
    /// ```
    func shouldNotify(conclusion: JobConclusion) -> Bool {
        switch notificationMode {
        case .all:           return true
        case .failuresOnly:  return conclusion.isFailure
        case .successesOnly: return conclusion == .success
        case .never:         return false
        }
    }
}
