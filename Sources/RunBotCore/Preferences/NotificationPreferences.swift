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
/// ## Why `final`
/// `final` prevents subclasses from shadowing `@Observable`-synthesised stored
/// properties or `@AppStorage` backing variables. The `@Observable` macro emits
/// `_$observationRegistrar` and per-property `_$id` accessors as concrete stored
/// members of this exact type; a subclass that re-declared any preference property
/// would silently shadow those members and break observation tracking in ways that
/// are extremely difficult to diagnose. `final` makes this a compile error.
/// Test isolation is achieved via constructor injection (`init(store:)`), not
/// subclassing — there is no testing use case that requires a subclass.
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
/// the call site: that bypasses the typed `notificationMode` accessor and
/// couples the call site to the raw key string this type exists to encapsulate.
///
/// ## notificationModeRaw access level
/// `notificationModeRaw` is `private`. External callers must use the typed
/// `notificationMode` accessor, which applies the `NotificationMode(rawValue:) ?? .never`
/// guard. Tests that need to inspect the persisted raw value use the `internal`
/// read-only `notificationModeRawValue` accessor — which exposes the value
/// without opening a write path to the whole module. This enforces the guard
/// at the language level rather than by doc convention.
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

    // Every @AppStorage property below also carries @ObservationIgnored.
    // This is REQUIRED — not redundant. Without it the @Observable macro
    // conflicts with @AppStorage's own compiler-generated backing storage
    // and produces a compile error. See ## @AppStorage + @ObservationIgnored
    // in the class doc above for the full explanation.
    //
    // ⚠️ NOT @Observable-tracked — withObservationTracking will NOT re-fire on change.
    // Use @Bindable against the owning instance for SwiftUI change propagation.
    // This is intentional and silent: reads compile fine, callbacks just never arrive.

    /// Raw `String` backing store for `notificationMode`.
    ///
    /// `private` — the compiler enforces that only this type's own code can write
    /// the raw value. External callers read via `notificationMode` (typed, guarded)
    /// or inspect via `notificationModeRawValue` (internal read-only, for tests).
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
    private var notificationModeRaw: String = NotificationMode.never.rawValue

    /// Read-only accessor for the raw persisted `String` value of `notificationMode`.
    ///
    /// **Intentionally test-only** — this property has no production callsite and
    /// that is correct. Production code always uses the typed `notificationMode`
    /// accessor. This property exists solely so `@testable import` test targets can
    /// assert on the raw persisted value (e.g. to verify UserDefaults round-trip
    /// correctness) without being granted a write path into `notificationModeRaw`.
    /// If it appears unused in production analysis tools or coverage reports, that
    /// is expected and not a signal to remove it.
    /// Read-only by design: the write path intentionally goes through `notificationMode`,
    /// which applies the `NotificationMode(rawValue:) ?? .never` guard.
    var notificationModeRawValue: String { notificationModeRaw }

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
    ///   **Non-standard suites must only be passed from test targets.**
    ///   Constructing a live, non-test instance with a non-standard suite is
    ///   unsupported: the orphaned `.standard` `NotificationCenter` subscription
    ///   described in `## @AppStorage subscription note` below would cause
    ///   spurious `@AppStorage` re-reads against `.standard` on every
    ///   `.standard` write — silently updating state from the wrong store.
    ///   In production, `shared` (which targets `.standard`) is the only
    ///   supported construction path.
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
    /// tests pass while asserting against the wrong store.
    ///
    /// ## Why there is no rebind canary assert
    /// A meaningful canary would need to read back through the rebound
    /// `@AppStorage` property (e.g. `assert(notificationModeRaw == sentinel)`) to
    /// prove the wrapper now targets the injected suite. That is not safely
    /// possible here: `@AppStorage` on a `@MainActor` class requires the actor
    /// to be fully initialised before stored properties are accessible during
    /// `init`. An assert on `store.object(forKey:) != nil` only proves
    /// `register(into:)` ran — already guaranteed unconditionally above — and
    /// gives false confidence rather than real verification. The correct
    /// verification is in the test suite: each test that injects a suite asserts
    /// reads and writes round-trip through that suite, which is a stronger and
    /// more legible guarantee than any init-time canary.
    ///
    /// ## @AppStorage subscription note
    /// At declaration time, `@AppStorage` registers an internal `NotificationCenter`
    /// subscription against `.standard`. After the test-injection rebind, reads and
    /// writes correctly target the injected suite, but that original `.standard`
    /// subscription is never torn down — this is a limitation of the `@AppStorage`
    /// API; there is no public teardown mechanism.
    /// In test targets this is harmless: tests are serialised on `@MainActor` and
    /// no test writes to `.standard` for these keys, so the undead subscription
    /// never fires. In production, `shared` always targets `.standard` so there
    /// is no split-brain. The hazard only arises if `init(store:)` is called with
    /// a non-standard suite outside a test target — which is explicitly unsupported;
    /// see the `store` parameter doc above.
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
            // No canary assert here — see ## Why there is no rebind canary assert.
            _notificationModeRaw = AppStorage(
                wrappedValue: NotificationMode.never.rawValue,
                Self.keyNotificationMode,
                store: store
            )
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
            Self.keyNotificationMode: NotificationMode.never.rawValue,
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
