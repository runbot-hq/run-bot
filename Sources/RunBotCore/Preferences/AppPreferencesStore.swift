// AppPreferencesStore.swift
// RunBotCore
import Foundation
import Observation
// SwiftUI is imported for @AppStorage only (showDimmedRunners, showPopoverArrow).
// betaChannel uses a stored var + didSet so that @Observable instruments its
// getter and setter automatically, and .onChange fires correctly.
// See ## betaChannel — why stored var, not computed or @AppStorage below.
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
/// ## @AppStorage + @ObservationIgnored (showDimmedRunners, showPopoverArrow)
/// These two properties use both `@AppStorage` and `@ObservationIgnored`.
/// This combination is required and intentional:
/// - `@AppStorage` is a property wrapper. Without `@ObservationIgnored`, the
///   `@Observable` macro tries to synthesise observation tracking for the
///   compiler-generated `_` backing variable, which conflicts with the wrapper's
///   own storage and produces a compile error. `@ObservationIgnored` suppresses
///   that instrumentation.
/// - `@Observable` tracking is intentionally absent for these two properties.
///   External observers that use `withObservationTracking` will NOT be notified
///   of changes — this is by design. Neither property has an `.onChange` handler
///   that needs to fire. UI updates go through SwiftUI's `@Bindable` / `@AppStorage`
///   channel, not through `@Observable`'s registrar.
///   **This failure mode is silent** — a `withObservationTracking` read compiles
///   and returns the correct value on first access; it just never re-fires.
///   Use `@Bindable` instead.
/// ⚠️ Do NOT apply this pattern to any property that needs `.onChange` to fire.
///   See ## betaChannel — why stored var, not computed or @AppStorage below.
///
/// ## betaChannel — why stored var, not computed or @AppStorage
/// `betaChannel` MUST be `@Observable`-tracked so that `.onChange(of: settings.betaChannel)`
/// fires in `UpdateSettingsSection.betaChannelRow`.
///
/// **Why not `@ObservationIgnored @AppStorage`:**
/// `@ObservationIgnored` suppresses `withMutation(keyPath:)` in the setter, so
/// the observation graph is never notified and `.onChange` never fires silently.
///
/// **Why not a computed property:**
/// `@Observable` only auto-instruments *stored* properties. For a hand-written
/// computed property, the macro sees an existing getter/setter body and leaves
/// them completely untouched — no `_$observationRegistrar.access(keyPath:)` in
/// the getter, no `_$observationRegistrar.withMutation(keyPath:)` in the setter.
/// The observation graph is never wired and `.onChange` never fires.
/// This was the root cause confirmed in #2183 (July 2026).
///
/// **Fix — stored var + didSet:**
/// `betaChannel` is a plain stored `var`. The `@Observable` macro instruments
/// its getter with `access(keyPath:)` and its setter with `withMutation(keyPath:)`
/// automatically. `didSet` persists the new value to `_store` (UserDefaults).
/// The stored var is seeded from UserDefaults in `init(store:)` after
/// `register(defaults:)`. `didSet` does NOT fire during init in Swift, so the
/// seed assignment is safe and will not double-write to UserDefaults.
///
/// ## Thread safety
/// `@MainActor`-isolated. All writes run on the main thread; no
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

    /// UserDefaults key for `automaticUpdatesEnabled`.
    /// Single source of truth — see `keyShowDimmedRunners` rationale.
    private static let keyAutomaticUpdatesEnabled = "settings.automaticUpdatesEnabled"

    // MARK: - Preferences

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume via `@Bindable`. See class-level `## @AppStorage + @ObservationIgnored`.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowDimmedRunners)
    public var showDimmedRunners: Bool = true

    /// INERT — has no effect. #2305 replaced the `NSPopover` this controlled with an
    /// owned panel, and the AppShell migration then replaced that panel with a plain
    /// `Window`; there has been no popover arrow to show or hide for two architectures.
    /// Preserved only to avoid silently dropping a persisted user default. It is not
    /// read anywhere — wire it to something meaningful or remove it along with the
    /// Settings toggle. Tracked in #3029.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowPopoverArrow)
    public var showPopoverArrow: Bool = true

    /// The UserDefaults suite used for `betaChannel` persistence.
    /// Assigned in `init(store:)` — `.standard` in production, injected suite in tests.
    /// `@ObservationIgnored` — this is infrastructure, not a user-facing preference.
    @ObservationIgnored
    private var _store: UserDefaults = .standard

    /// Whether to offer pre-release (beta) builds in the update check.
    ///
    /// When `true`, `UpdateChecker` will also consider pre-release GitHub releases
    /// when looking for a newer version. Defaults to `false` so users stay on the
    /// stable channel unless they explicitly opt in.
    ///
    /// ## Why stored var + didSet, not @AppStorage or computed
    /// `@Observable` only instruments stored properties. A computed property or
    /// `@ObservationIgnored @AppStorage` would both prevent `withMutation(keyPath:)`
    /// from being called, silently breaking `.onChange(of: settings.betaChannel)`.
    /// See class-level `## betaChannel — why stored var, not computed or @AppStorage`.
    ///
    /// Persistence is via `_store` (direct `UserDefaults` write in `didSet`), same
    /// key as before. The stored var is seeded from `_store` in `init(store:)`.
    /// Test injection works via `_store` assigned in `init(store:)`.
    public var betaChannel: Bool = false {
        didSet {
            guard oldValue != betaChannel else { return }
            #if DEBUG
            log(
                "【AppPreferencesStore.betaChannel.didSet】\(oldValue) → \(betaChannel)",
                category: .general
            )
            #endif
            _store.set(betaChannel, forKey: Self.keyBetaChannel)
            #if DEBUG
            log(
                "【AppPreferencesStore.betaChannel.didSet】persisted to \(Self.keyBetaChannel)",
                category: .general
            )
            #endif
        }
    }

    /// Whether the app performs automatic update checks and background scheduling.
    ///
    /// When `false`:
    /// - No launch-time update check runs.
    /// - The background scheduler remains registered but skips update work.
    /// - All update-phase UI in Settings is hidden.
    /// The `betaChannel` preference is unaffected by toggling this.
    ///
    /// Defaults to `true`. Follows the same stored-var + `didSet` pattern as
    /// `betaChannel` so `.onChange(of: settings.automaticUpdatesEnabled)` fires
    /// correctly in `UpdateSettingsSection`. See class-level `## betaChannel — why stored
    /// var, not computed or @AppStorage` for the rationale.
    public var automaticUpdatesEnabled: Bool = true {
        didSet {
            guard oldValue != automaticUpdatesEnabled else { return }
            #if DEBUG
            log(
                "【AppPreferencesStore.automaticUpdatesEnabled.didSet】\(oldValue) → \(automaticUpdatesEnabled)",
                category: .general
            )
            #endif
            _store.set(automaticUpdatesEnabled, forKey: Self.keyAutomaticUpdatesEnabled)
            #if DEBUG
            log(
                "【AppPreferencesStore.automaticUpdatesEnabled.didSet】persisted to \(Self.keyAutomaticUpdatesEnabled)",
                category: .general
            )
            #endif
        }
    }

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
    ///
    /// ## Why `public`
    /// Test targets are separate Swift modules and cannot call `internal` members
    /// even with `@testable import`.
    ///
    /// ## register(defaults:)
    /// Called unconditionally on every `init`. Cheap: writes only to the
    /// in-memory registration domain. Never overwrites user-set values.
    ///
    /// ## betaChannel seed
    /// `betaChannel` is a stored var seeded from UserDefaults after
    /// `register(defaults:)` runs. `didSet` does NOT fire during init in Swift —
    /// the assignment is safe and will not double-write to UserDefaults.
    ///
    /// ## @AppStorage subscription note
    /// `showDimmedRunners` and `showPopoverArrow` still use `@AppStorage`, which
    /// registers a `NotificationCenter` subscription against `.standard` at
    /// declaration time. After test-injection rebind, reads/writes target the
    /// injected suite, but the `.standard` subscription is not torn down
    /// (no public teardown API). Harmless in tests — see original doc for detail.
    public init(store: UserDefaults) {
        #if DEBUG
        log(
            "【AppPreferencesStore.init】store=\(store === UserDefaults.standard ? ".standard" : "injected")",
            category: .general
        )
        #endif
        // _store must be assigned before the betaChannel seed below so that
        // any post-init didSet on betaChannel writes to the injected suite.
        // NOTE: didSet does NOT fire on the seed assignment — Swift suppresses
        // didSet during init — so _store's value here has no effect on that
        // line. It matters only for runtime writes after init completes.
        _store = store
        store.register(defaults: [
            Self.keyShowDimmedRunners: true,
            Self.keyShowPopoverArrow: true,
            Self.keyBetaChannel: false,
            Self.keyAutomaticUpdatesEnabled: true,
        ])
        // Seed betaChannel from the (possibly injected) store.
        // didSet does NOT fire during init — no double-write to UserDefaults.
        betaChannel = store.bool(forKey: Self.keyBetaChannel)
        #if DEBUG
        log(
            "【AppPreferencesStore.init】betaChannel seeded from store: \(betaChannel)",
            category: .general
        )
        #endif
        // Seed automaticUpdatesEnabled. Same init-time safety as betaChannel above.
        automaticUpdatesEnabled = store.bool(forKey: Self.keyAutomaticUpdatesEnabled)
        #if DEBUG
        log(
            "【AppPreferencesStore.init】automaticUpdatesEnabled seeded from store: \(automaticUpdatesEnabled)",
            category: .general
        )
        #endif
        if store !== UserDefaults.standard {
            // Re-target @AppStorage wrappers to the injected test suite.
            // betaChannel has no @AppStorage wrapper — _store handles it above.
            _showDimmedRunners = AppStorage(
                wrappedValue: true,
                Self.keyShowDimmedRunners,
                store: store
            )
            _showPopoverArrow = AppStorage(
                wrappedValue: true,
                Self.keyShowPopoverArrow,
                store: store
            )
            #if DEBUG
            log(
                "【AppPreferencesStore.init】test suite injected — @AppStorage wrappers rebound",
                category: .general
            )
            #endif
        }
    }
}
