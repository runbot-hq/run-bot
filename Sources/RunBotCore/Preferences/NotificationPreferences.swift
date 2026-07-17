// NotificationPreferences.swift
// RunBotCore
import Foundation
import Observation
// SwiftUI is imported for @AppStorage only. See the class-level
// ## @AppStorage + @ObservationIgnored doc for the full rationale.
// Outside a SwiftUI view hierarchy @AppStorage degrades gracefully to a
// plain UserDefaults read/write; persistence correctness is unaffected.
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
/// the `@AppStorage` backing wrapper is re-pointed to that suite so unit tests
/// can supply an ephemeral suite without polluting the real preferences database.
///
/// ## @AppStorage + @ObservationIgnored
/// `notificationModeRaw` uses both `@AppStorage` and `@ObservationIgnored`.
/// This combination is required and intentional:
/// - `@AppStorage` is a property wrapper. Without `@ObservationIgnored`, the
///   `@Observable` macro tries to synthesise observation tracking for the
///   compiler-generated `_` backing variable, which conflicts with the wrapper's
///   own storage and produces a compile error. `@ObservationIgnored` suppresses
///   that instrumentation.
/// - Outside a SwiftUI view hierarchy `@AppStorage` still reads/writes
///   `UserDefaults` correctly. Change propagation to views happens via
///   `@Bindable` on the owning instance, not through the SwiftUI environment.
/// - `@Observable` tracking is intentionally absent for `notificationModeRaw`.
///   External `withObservationTracking` observers will NOT be notified of
///   changes — this is by design. UI updates go through `@Bindable` / `@AppStorage`.
///   **This failure mode is silent** — reads compile fine and return correct values;
///   change callbacks simply never arrive. Use `@Bindable` instead.
///
/// ## notificationMode — intentionally untracked computed property
/// `notificationMode` is a computed property. The `@Observable` macro only
/// auto-instruments **stored** properties — computed properties never receive
/// `_$observationRegistrar` calls regardless of any attributes. `notificationMode`
/// therefore does NOT participate in the `@Observable` change-tracking graph.
/// A `withObservationTracking` consumer reading `notificationMode` will remain
/// valid but will NOT be re-invoked when the value changes (silently stale).
/// This is intentional — the correct binding pattern is `@Bindable`; see
/// ## SwiftUI consumption below.
///
/// ## SwiftUI consumption
/// Bind via `@Bindable` on the `shared` instance against `notificationMode`
/// directly — the setter writes through to `notificationModeRaw` and
/// `@AppStorage` propagates the change to the view.
/// Do NOT bind via a raw `@AppStorage("notifications.notificationMode")` at
/// the call site: that bypasses the `internal` access guard on `notificationModeRaw`
/// and couples the call site to the raw key string this type exists to encapsulate.
///
/// ## notificationModeRaw access level
/// `notificationModeRaw` is `internal`, not `public`. This is intentional:
/// external callers must go through `notificationMode`, which applies the
/// `NotificationMode(rawValue:) ?? .never` guard. It is not `private` so that
/// `@testable import` test targets can inspect the raw stored value directly.
/// Note: because this is an app target (not a library), a `public extension` on
/// `NotificationPreferences` in another file could technically re-expose this
/// property. That is undesirable — any such extension must not redeclare or
/// proxy `notificationModeRaw` as public.
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

    // MARK: - Keys

    /// UserDefaults key for `notificationModeRaw`.
    /// Single source of truth — used in `register(into:)`, the `@AppStorage`
    /// declaration, and the test-injection `AppStorage(...)` constructor so a
    /// rename is a compile error, not a silent split-brain.
    private static let keyNotificationMode = "notifications.notificationMode"

    // MARK: - Preferences

    /// Raw `String` backing store for `notificationMode`.
    ///
    /// `internal` intentionally — external callers must use the typed
    /// `notificationMode` accessor which applies the `?? .never` guard.
    /// Not `private` so `@testable import` test targets can inspect it directly.
    /// See class-level ## notificationModeRaw access level.
    ///
    /// `@ObservationIgnored` is required here (not redundant) — see
    /// class-level ## @AppStorage + @ObservationIgnored.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume `notificationMode` (the typed accessor) via `@Bindable` instead.
    ///
    /// Default changed from `.all` to `.never` in #2082.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(NotificationPreferences.keyNotificationMode)
    var notificationModeRaw: String = NotificationMode.never.rawValue

    /// Typed read/write accessor for the notification mode preference.
    /// Persisted as a `String` rawValue in UserDefaults via `notificationModeRaw`.
    ///
    /// Writes update `notificationModeRaw` (and therefore UserDefaults) atomically.
    /// Unrecognised raw values fall back to `.never` (e.g. after a downgrade).
    ///
    /// ## Observation tracking — intentionally absent
    /// This is a computed property. The `@Observable` macro never instruments
    /// computed properties — no `_$observationRegistrar` calls are emitted here
    /// regardless of any attribute. `withObservationTracking` consumers reading
    /// this property will NOT be re-invoked on change. Use `@Bindable` instead;
    /// see class-level ## SwiftUI consumption.
    ///
    /// ## Dispatch wiring
    /// Wired in #2070. Call `shouldNotify(conclusion:)` at every
    /// `UNUserNotificationCenter` dispatch site to gate notifications.
    public var notificationMode: NotificationMode {
        get { NotificationMode(rawValue: notificationModeRaw) ?? .never }
        set { notificationModeRaw = newValue.rawValue }
    }

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    /// `private` — all production code must go through `shared`.
    private convenience init() {
        self.init(store: .standard)
    }

    /// Designated initialiser.
    ///
    /// - Parameter store: The `UserDefaults` suite to use. Pass `.standard` in
    ///   production (via `shared`) or an ephemeral suite in unit tests (P7).
    ///
    /// ## Why `public`
    /// Required for test-target injection (P7) — test targets are separate modules
    /// and cannot access `internal` members. The `private convenience init()`
    /// ensures zero-argument construction outside this file still routes through
    /// `shared`. Making `init(store:)` public is intentional, not an oversight.
    ///
    /// ## @MainActor safety
    /// Isolation is enforced by the class declaration. Calling this off the main
    /// actor is a compile error; there is no race hazard from `public` visibility.
    ///
    /// ## register(defaults:)
    /// Delegated to `Self.register(into: store)` — single registration body,
    /// no duplication. Called **unconditionally** before the `if` branch so that
    /// direct `UserDefaults` readers see `"never"` on first launch instead of `nil`.
    /// Never overwrites persisted values.
    ///
    /// ## Test-injection path (`if store !== .standard`)
    /// Re-targets `@AppStorage` via the compiler-synthesised `_notificationModeRaw`
    /// backing wrapper. This relies on the stable `_propertyName` naming convention
    /// for `@propertyWrapper` backing storage — a de-facto Swift standard, not an
    /// ABI guarantee. Extremely unlikely to change, but worth knowing if a future
    /// Swift or SwiftUI toolchain update causes unexpected test failures here.
    /// **Failure mode if broken:** reads silently fall back to `.standard` —
    /// tests pass while asserting against the wrong store. The `#if DEBUG` canary
    /// assert at the rebind site below will catch this at test runtime.
    ///
    /// ## @AppStorage subscription note
    /// At declaration time, `@AppStorage` registers an internal `NotificationCenter`
    /// subscription against `.standard`. After the test-injection rebind, reads and
    /// writes correctly target the injected suite, but that original `.standard`
    /// subscription is never torn down. In practice this is harmless — tests are
    /// serialised on `@MainActor` so cross-suite notification bleed cannot race —
    /// but it is worth knowing if flaky main-actor test behaviour appears.
    ///
    /// ## wrappedValue semantics
    /// `AppStorage(wrappedValue:_:store:)` first argument is a fallback default
    /// used only when the key is absent. Because `register(into:)` has already
    /// run, the key is always present and `@AppStorage` reads it directly from
    /// `store` on first property access, silently ignoring `wrappedValue` entirely.
    /// The declaration-site literal (`NotificationMode.never.rawValue`) is used
    /// here — it is never observed at runtime but makes the intended default
    /// legible without implying the store is being read.
    public init(store: UserDefaults) {
        // Single registration body — delegates to the public static method so
        // there is no duplication between init and register(into:).
        Self.register(into: store)
        if store !== UserDefaults.standard {
            // Re-target @AppStorage to the injected test suite via the
            // compiler-synthesised _ backing wrapper. See ## Test-injection path
            // in the doc above for the stability note on this pattern.
            // wrappedValue is a fallback default only — never observed at runtime.
            _notificationModeRaw = AppStorage(
                wrappedValue: NotificationMode.never.rawValue,
                Self.keyNotificationMode,
                store: store
            )
            // Canary: if the _ rebind pattern ever breaks (Swift/SwiftUI toolchain
            // change), reads will silently fall back to .standard instead of the
            // injected suite. Assert here so test failures are obvious rather than
            // manifesting as wrong-store assertions passing silently.
            #if DEBUG
            assert(
                store.object(forKey: Self.keyNotificationMode) != nil,
                "NotificationPreferences test-injection canary: injected suite has no registered defaults. "
                + "register(into:) must run before the _backing rebind."
            )
            #endif
        }
        // else: production path — @AppStorage already targets .standard by
        // default at the declaration site; no rebinding needed.
    }

    // MARK: - Registration

    /// Registers factory defaults into `store`.
    ///
    /// `init(store:)` delegates to this method — it is the **single registration
    /// body** for this type. This method is `public` for **external test setup
    /// only**: call it when code reads `UserDefaults` directly before constructing
    /// a `NotificationPreferences` instance. Production callers should use `shared`
    /// and never need to call this directly.
    ///
    /// - Parameter store: The `UserDefaults` instance to register defaults into.
    ///
    /// Default changed from `.all` to `.never` in #2082.
    public static func register(into store: UserDefaults) {
        store.register(defaults: [
            keyNotificationMode: NotificationMode.never.rawValue,
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
