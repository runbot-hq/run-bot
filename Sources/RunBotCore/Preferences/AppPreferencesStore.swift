// AppPreferencesStore.swift
// RunBotCore
import Foundation
import Observation

// MARK: - AppPreferencesStore

/// Persists general app settings to UserDefaults.
///
/// ## Dependency injection (P7)
/// `init(store:)` accepts a `UserDefaults` suite so unit tests can inject an
/// ephemeral in-memory suite instead of polluting `.standard`. Production code
/// always uses the `shared` singleton, which calls `init()` → `init(store: .standard)`.
///
/// ## Thread safety
/// `@MainActor`-isolated. All `didSet` writes run on the main thread; no additional
/// synchronisation is needed.
///
/// ## pollingInterval removal (Step 10, #2069)
/// `pollingInterval` and `pollingRange` were removed from this type because
/// `RunnerPoller` no longer reads them — poll cadence is fully driven by
/// `PollIntervalStrategy`. The `settings.pollingInterval` UserDefaults key is
/// no longer registered in `register(defaults:)` (removed in this step) and goes
/// unread by the app. Existing installs that previously wrote a value retain it
/// in UserDefaults but it has no effect.
@MainActor
@Observable
public final class AppPreferencesStore {
    /// Shared singleton — use this instead of calling init directly.
    public static let shared = AppPreferencesStore()

    /// UserDefaults key constants used by `AppPreferencesStore`.
    private enum Key {
        /// Key for the show-dimmed-runners toggle.
        static let showDimmedRunners = "settings.showDimmedRunners"
        /// Key for the show-popover-arrow toggle.
        static let showPopoverArrow = "settings.showPopoverArrow"
        /// Key for the beta channel toggle.
        static let betaChannel = "settings.betaChannel"
    }

    // MARK: - Backing store

    /// The `UserDefaults` instance used for all reads and writes.
    /// Injected at init; defaults to `.standard` in production.
    private let defaults: UserDefaults

    // MARK: - Preferences

    /// Whether to show dimmed (offline/idle) runners in the runners list.
    ///
    /// Retained for UserDefaults backwards-compatibility only — no longer surfaced
    /// in the UI (#510). Do not remove: removing would break the stored key for
    /// users upgrading from older versions.
    public var showDimmedRunners: Bool {
        didSet { defaults.set(showDimmedRunners, forKey: Key.showDimmedRunners) }
    }

    /// Whether the NSPopover anchor arrow is shown.
    ///
    /// When `false`, the arrow is suppressed on the next popover open via the
    /// private-but-widely-used KVC key `shouldHideAnchor` on `NSPopover`.
    /// Default is `true` so existing users see no behaviour change on upgrade.
    ///
    /// Takes effect on the next `openPanel()` call — the arrow state is baked in
    /// at `popover.show()` time and cannot be changed mid-session.
    public var showPopoverArrow: Bool {
        didSet { defaults.set(showPopoverArrow, forKey: Key.showPopoverArrow) }
    }

    /// Whether to offer pre-release (beta) builds in the update check.
    ///
    /// When `true`, `UpdateChecker` will also consider pre-release GitHub releases
    /// when looking for a newer version. Defaults to `false` so users stay on the
    /// stable channel unless they explicitly opt in.
    public var betaChannel: Bool {
        didSet { defaults.set(betaChannel, forKey: Key.betaChannel) }
    }

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
    public init(store: UserDefaults) {
        self.defaults = store
        store.register(defaults: [
            Key.showDimmedRunners: true,
            Key.showPopoverArrow: true,
            Key.betaChannel: false,
        ])
        showDimmedRunners = store.bool(forKey: Key.showDimmedRunners)
        showPopoverArrow = store.bool(forKey: Key.showPopoverArrow)
        betaChannel = store.bool(forKey: Key.betaChannel)
    }
}
