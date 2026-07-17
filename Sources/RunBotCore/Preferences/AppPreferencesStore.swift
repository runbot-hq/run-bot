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

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would orphan the stored key for
    /// users upgrading from older versions.
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
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyShowPopoverArrow)
    public var showPopoverArrow: Bool = true

    /// Whether to offer pre-release (beta) builds in the update check.
    ///
    /// When `true`, `UpdateChecker` will also consider pre-release GitHub releases
    /// when looking for a newer version. Defaults to `false` so users stay on the
    /// stable channel unless they explicitly opt in.
    @ObservationIgnored // required — see class-level ## @AppStorage + @ObservationIgnored
    @AppStorage(AppPreferencesStore.keyBetaChannel)
    public var betaChannel: Bool = false

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
    /// ## register(defaults:)
    /// Called **unconditionally** — including on the production `.standard` path.
    /// This seeds the UserDefaults registration domain so that any direct
    /// `UserDefaults` reader (migration helpers, analytics, crash reporters)
    /// sees the correct value on first launch rather than the zero-value `false`.
    /// `register(defaults:)` only sets keys that are absent; it never overwrites
    /// persisted values, so upgrading users are unaffected.
    ///
    /// ## Test-injection path (`if store !== .standard`)
    /// When a non-standard suite is injected (unit tests), each `@AppStorage`
    /// property is re-targeted to that suite by re-initialising its `_` backing
    /// wrapper directly. The production path skips this block entirely because
    /// `@AppStorage` already targets `.standard` by default at the declaration site.
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
        store.register(defaults: [
            Self.keyShowDimmedRunners: true,
            Self.keyShowPopoverArrow: true,
            Self.keyBetaChannel: false,
        ])
        if store !== UserDefaults.standard {
            // Re-target each @AppStorage to the injected test suite.
            // wrappedValue is a fallback default only — @AppStorage reads the key
            // directly from store on first access regardless of this value.
            // Literals match the declaration-site defaults above.
            _showDimmedRunners = AppStorage(wrappedValue: true, Self.keyShowDimmedRunners, store: store)
            _showPopoverArrow = AppStorage(wrappedValue: true, Self.keyShowPopoverArrow, store: store)
            _betaChannel = AppStorage(wrappedValue: false, Self.keyBetaChannel, store: store)
        }
        // else: production path — @AppStorage already targets .standard by
        // default at the declaration site; no rebinding needed.
    }
}
