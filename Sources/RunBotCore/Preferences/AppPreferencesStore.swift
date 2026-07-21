// AppPreferencesStore.swift
// RunBotCore
import Foundation
import Observation
// SwiftUI is imported for @AppStorage only (showDimmedRunners, showPopoverArrow).
// betaChannel no longer uses @AppStorage — it is a computed property backed by
// _store directly so that @Observable instruments its setter and .onChange fires.
// See ## betaChannel — why computed, not @AppStorage below.
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
///   See ## betaChannel — why computed, not @AppStorage below.
///
/// ## betaChannel — why computed, not @AppStorage
/// `betaChannel` cannot use `@ObservationIgnored @AppStorage` because
/// `SettingsView+Sections` attaches `.onChange(of: settings.betaChannel)`
/// to trigger an immediate update check when the user toggles the beta switch.
/// `.onChange` subscribes through the `@Observable` observation graph.
/// `@ObservationIgnored` suppresses the `withMutation(keyPath:)` call in the
/// setter, so the observation graph is never notified and `.onChange` never fires.
/// This was the root cause of the install button never appearing on beta toggle
/// (introduced July 17, root-caused in #2177).
///
/// Fix: `betaChannel` is a computed property. The getter reads `_store` directly;
/// the setter writes `_store` directly. Because the property has no `@ObservationIgnored`
/// attribute, the `@Observable` macro instruments the computed setter with
/// `withMutation(keyPath:)` — the observation graph is notified on every write and
/// `.onChange` fires correctly. Persistence is identical to the old `@AppStorage`
/// path — same key (`settings.betaChannel`), same `UserDefaults` suite.
/// Test injection works via `_store`, which is assigned from the injected suite
/// in `init(store:)` before `register(defaults:)` runs.
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

    // MARK: - Preferences

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// ⚠️ Not `@Observable`-tracked — `withObservationTracking` will not re-fire.
    /// Consume via `@Bindable`. See class-level `## @AppStorage + @ObservationIgnored`.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowDimmedRunners)
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
    /// ## Why computed, not @AppStorage
    /// This property MUST be `@Observable`-tracked so that `.onChange(of: settings.betaChannel)`
    /// fires in `SettingsView+Sections.betaChannelRow`. `@ObservationIgnored @AppStorage`
    /// suppresses `withMutation(keyPath:)` and breaks `.onChange` silently.
    /// See class-level `## betaChannel — why computed, not @AppStorage`.
    ///
    /// Persistence is via `_store` (direct `UserDefaults` read/write), same key as before.
    /// Test injection works via `_store` assigned in `init(store:)`.
    public var betaChannel: Bool {
        get {
            let value = _store.bool(forKey: Self.keyBetaChannel)
            log(
                "【AppPreferencesStore.betaChannel.get】value=\(value)",
                category: .general
            )
            return value
        }
        set {
            log(
                "【AppPreferencesStore.betaChannel.set】old=\(_store.bool(forKey: Self.keyBetaChannel)) new=\(newValue)",
                category: .general
            )
            _store.set(newValue, forKey: Self.keyBetaChannel)
            log(
                "【AppPreferencesStore.betaChannel.set】persisted to UserDefaults key=\(Self.keyBetaChannel) store=\(_store)",
                category: .general
            )
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
    /// ## betaChannel test injection
    /// `betaChannel` no longer uses `@AppStorage`, so there is no `_betaChannel`
    /// backing wrapper to rebind. Test injection for `betaChannel` works via
    /// `_store`, which is assigned from the injected suite before `register(defaults:)`
    /// runs. Reads and writes in tests target the injected suite automatically.
    ///
    /// ## @AppStorage subscription note
    /// `showDimmedRunners` and `showPopoverArrow` still use `@AppStorage`, which
    /// registers a `NotificationCenter` subscription against `.standard` at
    /// declaration time. After test-injection rebind, reads/writes target the
    /// injected suite, but the `.standard` subscription is not torn down
    /// (no public teardown API). Harmless in tests — see original doc for detail.
    public init(store: UserDefaults) {
        log(
            "【AppPreferencesStore.init】store=\(store === UserDefaults.standard ? ".standard" : "injected")",
            category: .general
        )
        // Assign _store before register(defaults:) so betaChannel computed
        // property targets the correct suite from the first read.
        _store = store
        store.register(defaults: [
            Self.keyShowDimmedRunners: true,
            Self.keyShowPopoverArrow: true,
            Self.keyBetaChannel: false,
        ])
        log(
            "【AppPreferencesStore.init】register(defaults:) done — betaChannel=\(store.bool(forKey: Self.keyBetaChannel))",
            category: .general
        )
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
            log(
                "【AppPreferencesStore.init】test suite injected — @AppStorage wrappers rebound",
                category: .general
            )
        }
    }
}
