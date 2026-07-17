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
/// ## @AppStorage
/// Properties use `@AppStorage` for the production path (`.standard`). When a
/// non-standard suite is injected (test path), `@AppStorage` is re-pointed to that
/// suite via the `store:` overload so test isolation is preserved (P7).
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
    /// When `store` is not `.standard`, each `@AppStorage` property is
    /// re-initialised against `store` so test isolation is preserved.
    public init(store: UserDefaults) {
        if store !== UserDefaults.standard {
            _showDimmedRunners = AppStorage(
                wrappedValue: store.bool(forKey: "settings.showDimmedRunners") == false
                    && store.object(forKey: "settings.showDimmedRunners") == nil ? true
                    : store.bool(forKey: "settings.showDimmedRunners"),
                "settings.showDimmedRunners",
                store: store
            )
            _showPopoverArrow = AppStorage(
                wrappedValue: store.bool(forKey: "settings.showPopoverArrow") == false
                    && store.object(forKey: "settings.showPopoverArrow") == nil ? true
                    : store.bool(forKey: "settings.showPopoverArrow"),
                "settings.showPopoverArrow",
                store: store
            )
            _betaChannel = AppStorage(
                wrappedValue: store.bool(forKey: "settings.betaChannel"),
                "settings.betaChannel",
                store: store
            )
        }
    }
}
