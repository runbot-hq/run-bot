// AppPreferencesStore.swift
// RunBotCore
import Foundation
import Observation
// SwiftUI is imported for @AppStorage only. @AppStorage is used here as a
// UserDefaults-backed property wrapper with SwiftUI-style change publishing.
// Outside a SwiftUI view hierarchy it degrades gracefully to a plain
// UserDefaults read/write — persistence correctness is unaffected. The
// import is intentional and reviewed; see ## @AppStorage + @ObservationIgnored
// in the class doc for the full rationale.
import SwiftUI

// MARK: - AppPreferencesStore

/// Persists general app settings to UserDefaults.
///
/// ## Dependency injection (P7)
/// `init(store:)` accepts a `UserDefaults` suite so unit tests can inject an
/// ephemeral in-memory suite instead of polluting `.standard`. Production code
/// always uses the `shared` singleton, which calls `init()` → `init(store: .standard)`.
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
/// Every stored preference uses both `@AppStorage` and `@ObservationIgnored`.
/// This combination is required and intentional:
/// - `@AppStorage` is a property wrapper. Without `@ObservationIgnored`, the
///   `@Observable` macro tries to synthesise observation tracking for the
///   compiler-generated `_` backing variable, which conflicts with the wrapper's
///   own storage and produces a compile error. `@ObservationIgnored` suppresses
///   that instrumentation.
/// - Outside a SwiftUI view hierarchy `@AppStorage` still reads/writes
///   `UserDefaults` correctly. Change propagation to SwiftUI views happens when
///   a view accesses the property via `@Bindable` on the owning instance — not
///   through the SwiftUI environment. This is the correct and intended pattern
///   for model types; `@AppStorage` does not require a view context to persist.
/// - `@Observable` tracking is intentionally absent for these stored properties.
///   External observers that use `withObservationTracking` will NOT be notified
///   of changes — this is by design. UI updates go through SwiftUI's `@Bindable`
///   / `@AppStorage` channel, not through `@Observable`'s registrar.
///   **This failure mode is silent** — a `withObservationTracking` read compiles
///   and returns the correct value on first access; it just never re-fires.
///   Use `@Bindable` instead. See per-property callouts below.
///
/// ## Thread safety
/// `@MainActor`-isolated. All `@AppStorage` writes run on the main thread; no
/// additional synchronisation is needed.
///
/// ## pollingInterval removal (Step 10, #2069)
/// `pollingInterval` and `pollingRange` were removed from this type because
/// `RunnerPoller` no longer reads them — poll cadence is fully driven by
/// `PollIntervalStrategy`. The `settings.pollingInterval` UserDefaults key is
/// no longer registered and goes unread by the app. Existing installs that
/// previously wrote a value retain it in UserDefaults but it has no effect.
@MainActor
@Observable
public final class AppPreferencesStore {
    /// Shared singleton — use this instead of calling `init` directly.
    /// `private convenience init()` is `private` — all production code must go through `shared`.
    public static let shared = AppPreferencesStore()

    // MARK: - Keys

    /// UserDefaults key for `showDimmedRunners`.
    /// Single source of truth — used in `register(defaults:)` and `AppStorage(...)` so a
    /// rename is a compile error, not a silent split-brain.
    private static let keyShowDimmedRunners = "settings.showDimmedRunners"

    /// UserDefaults key for `showPopoverArrow`.
    /// Single source of truth — see `keyShowDimmedRunners` rationale.
    private static let keyShowPopoverArrow = "settings.showPopoverArrow"

    /// UserDefaults key for `betaChannel`.
    /// Single source of truth — see `keyShowDimmedRunners` rationale.
    private static let keyBetaChannel = "settings.betaChannel"

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

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would orphan the stored key for
    /// users upgrading from older versions, causing `UserDefaults.bool(forKey:)` at
    /// any direct call site to silently return `false` (the zero value) rather than
    /// the registration default of `true` — a behaviour change invisible to those
    /// callers. The property must remain registered in `register(defaults:)` even if
    /// no UI surface ever reads it again.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume via `@Bindable`. See class-level `## @AppStorage + @ObservationIgnored`.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowDimmedRunners)
    // ↑ Declaration context: Self. is not available here (no implicit self in attribute
    // arguments). AppPreferencesStore.key… is used at the declaration site; Self.key…
    // is used inside init(store:) and other method bodies where `self` is in scope.
    // The difference is purely syntactic — both resolve to the identical static property.
    public var showDimmedRunners: Bool = true

    /// Whether the NSPopover anchor arrow is shown.
    ///
    /// When `false`, the arrow is suppressed on the next popover open via the
    /// private-but-widely-used KVC key `shouldHideAnchor` on `NSPopover`.
    /// Default is `true` so existing users see no behaviour change on upgrade.
    ///
    /// Takes effect on the next `openPanel()` call — the arrow state is baked in
    /// at `popover.show()` time and cannot be changed mid-session.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume via `@Bindable`. See class-level `## @AppStorage + @ObservationIgnored`.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowPopoverArrow)
    // ↑ Declaration context — AppPreferencesStore.key… not Self.key… for the same
    // reason as keyShowDimmedRunners above.
    public var showPopoverArrow: Bool = true

    /// Whether to offer pre-release (beta) builds in the update check.
    ///
    /// When `true`, `UpdateChecker` will also consider pre-release GitHub releases
    /// when looking for a newer version. Defaults to `false` so users stay on the
    /// stable channel unless they explicitly opt in.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume via `@Bindable`. See class-level `## @AppStorage + @ObservationIgnored`.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyBetaChannel)
    // ↑ Declaration context — AppPreferencesStore.key… not Self.key… for the same
    // reason as keyShowDimmedRunners above.
    public var betaChannel: Bool = false

    // MARK: - Init

    /// Convenience initialiser for production use. Calls `init(store: .standard)`.
    /// `private` — all production code must go through `shared`.
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
    ///   **Non-standard suites must only be passed from test targets.**
    ///   Constructing a live, non-test instance with a non-standard suite is
    ///   unsupported: the orphaned `.standard` `NotificationCenter` subscription
    ///   described in `## @AppStorage subscription note` below would cause
    ///   spurious `@AppStorage` re-reads against `.standard` on every
    ///   `.standard` write — silently updating UI state from the wrong store.
    ///   In production, `shared` (which targets `.standard`) is the only
    ///   supported construction path.
    ///
    /// ## register(defaults:)
    /// Called **unconditionally** on every `init` — including on every production
    /// app launch via `shared`. This is intentional and cheap: `register(defaults:)`
    /// only writes to the registration domain (an in-memory overlay), never to the
    /// persisted store. It never overwrites user-set values — if a key is already
    /// present in any domain, the registration value is silently ignored. The cost
    /// is a dictionary lookup per key, negligible relative to app startup. Calling
    /// it every launch ensures the registration domain is always populated,
    /// regardless of launch order or whether other code has called
    /// `removePersistentDomain(forName:)` in a test.
    ///
    /// ## No public `register(into:)` — by design
    /// Unlike `NotificationPreferences`, this type has no public static
    /// `register(into:)` method. There are no known external callers that need
    /// to seed these keys before constructing an `AppPreferencesStore` instance.
    /// If that requirement arises, add a parallel `public static func register(into:)`
    /// following the same pattern as `NotificationPreferences`.
    /// Note: if new keys are added to `AppPreferencesStore`, they must be added to
    /// the `register(defaults:)` dictionary below — there is no centralised static
    /// method to update. This is the accepted drift risk of the inline pattern;
    /// the mitigation is to extract `register(into:)` at that point.
    ///
    /// ## Test-injection path (`if store !== .standard`)
    /// When a non-standard suite is injected (unit tests), each `@AppStorage`
    /// property is re-targeted to that suite by re-initialising its compiler-
    /// synthesised `_` backing wrapper directly. This relies on the stable
    /// `_propertyName` naming convention for `@propertyWrapper` backing storage —
    /// a de-facto Swift standard, not an ABI guarantee. It is the accepted idiom
    /// for this pattern (used identically in `NotificationPreferences`) and is
    /// extremely unlikely to change, but worth knowing if a future Swift or
    /// SwiftUI toolchain update causes unexpected test failures here.
    /// **Failure mode if broken:** reads silently fall back to `.standard` —
    /// tests pass while asserting against the wrong store.
    ///
    /// ## Why there is no rebind canary assert
    /// A meaningful canary would need to read back through the rebound
    /// `@AppStorage` property (e.g. `assert(showDimmedRunners == sentinel)`) to
    /// prove the wrapper now targets the injected suite. That is not safely
    /// possible here: `@AppStorage` on a `@MainActor` class requires the actor
    /// to be fully initialised before stored properties are accessible, and
    /// `@AppStorage.wrappedValue` on `Bool` gives no sentinel-friendly type to
    /// distinguish a real stored value from a fallback default. An assert on
    /// `store.object(forKey:) != nil` only proves `register(defaults:)` ran —
    /// which is already guaranteed unconditionally above it — and gives false
    /// confidence. The correct verification is in the test suite: each test that
    /// injects a suite asserts reads and writes round-trip through that suite,
    /// which is a stronger and more legible guarantee than any init-time canary.
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
    /// `AppStorage(wrappedValue:_:store:)` — the first argument is a fallback
    /// default used only when the key is absent from `store`. Because
    /// `register(defaults:)` has already run, the key is always present and
    /// `@AppStorage` reads it directly from `store` on first property access,
    /// silently ignoring `wrappedValue` entirely. Plain declaration-site literals
    /// are used here — they are never observed at runtime but make the intended
    /// default legible without implying the store is being read.
    public init(store: UserDefaults) {
        // Register unconditionally — seeds .standard on production first-launch
        // and the injected suite in tests. Never overwrites existing values.
        // Cheap: writes only to the in-memory registration domain. Safe to call
        // on every app launch. See ## register(defaults:) in the doc above.
        store.register(defaults: [
            Self.keyShowDimmedRunners: true,
            Self.keyShowPopoverArrow: true,
            Self.keyBetaChannel: false,
        ])
        if store !== UserDefaults.standard {
            // Re-target each @AppStorage to the injected test suite via the
            // compiler-synthesised _ backing wrapper. See ## Test-injection path
            // in the doc above for the stability note on this pattern.
            // wrappedValue is a fallback default only — never observed at runtime.
            // No canary assert here — see ## Why there is no rebind canary assert.
            // Self.key… (not AppPreferencesStore.key…) is valid here: Self. is
            // available in method bodies; the attribute-argument restriction that
            // forced the type-name spelling at the declaration site does not apply.
            _showDimmedRunners = AppStorage(wrappedValue: true, Self.keyShowDimmedRunners, store: store)
            _showPopoverArrow = AppStorage(wrappedValue: true, Self.keyShowPopoverArrow, store: store)
            _betaChannel = AppStorage(wrappedValue: false, Self.keyBetaChannel, store: store)
        }
        // else: production path — @AppStorage already targets .standard by
        // default at the declaration site; no rebinding needed.
    }
}
