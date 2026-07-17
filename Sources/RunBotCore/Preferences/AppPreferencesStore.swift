// AppPreferencesStore.swift
// RunBotCore
import Foundation
import Observation
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
///   `@Observable` macro would try to synthesise observation tracking for the
///   compiler-generated `_` backing variable, which conflicts with the wrapper's
///   own storage and produces a compile error.
/// - `@ObservationIgnored` suppresses that instrumentation. This is safe because
///   `@AppStorage` publishes its own changes via the SwiftUI environment; it does
///   not need `@Observable`'s registrar. SwiftUI views bind directly to the
///   `@AppStorage` property and receive updates through that channel.
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
    /// Shared singleton — use this instead of calling init directly.
    public static let shared = AppPreferencesStore()

    // MARK: - Preferences

    // @ObservationIgnored is required on every @AppStorage property in this
    // @Observable class — see the class-level doc comment for the full rationale.

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would break the stored key for
    /// users upgrading from older versions.
    @ObservationIgnored
    @AppStorage("settings.showDimmedRunners")
    public var showDimmedRunners: Bool = true

    /// Whether the NSPopover anchor arrow is shown.
    ///
    /// When `false`, the arrow is suppressed on the next popover open via the
    /// private-but-widely-used KVC key `shouldHideAnchor` on `NSPopover`.
    /// Default is `true` so existing users see no behaviour change on upgrade.
    ///
    /// Takes effect on the next `openPanel()` call — the arrow state is baked in
    /// at `popover.show()` time and cannot be changed mid-session.
    @ObservationIgnored
    @AppStorage("settings.showPopoverArrow")
    public var showPopoverArrow: Bool = true

    /// Whether to offer pre-release (beta) builds in the update check.
    ///
    /// When `true`, `UpdateChecker` will also consider pre-release GitHub releases
    /// when looking for a newer version. Defaults to `false` so users stay on the
    /// stable channel unless they explicitly opt in.
    @ObservationIgnored
    @AppStorage("settings.betaChannel")
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
    /// ## wrappedValue semantics
    /// `AppStorage(wrappedValue:_:store:)` — the first argument is the fallback
    /// default used when the key is absent from `store`, not a forced seed value.
    /// When the key is already present, `@AppStorage` reads it from `store`
    /// directly and ignores `wrappedValue` entirely. Passing the plain default
    /// literal here is therefore correct and sufficient for all three properties.
    public init(store: UserDefaults) {
        if store !== UserDefaults.standard {
            _showDimmedRunners = AppStorage(
                wrappedValue: true,
                "settings.showDimmedRunners",
                store: store
            )
            _showPopoverArrow = AppStorage(
                wrappedValue: true,
                "settings.showPopoverArrow",
                store: store
            )
            _betaChannel = AppStorage(
                wrappedValue: false,
                "settings.betaChannel",
                store: store
            )
        }
    }
}
