// EnvironmentValues+RunBot.swift
// RunBot
//
// Custom SwiftUI environment keys used by the RunBot app target.
// All keys are defined here so they are discoverable in a single place.
import SwiftUI

// MARK: - suppressHidePanel

/// Environment key for the `suppressHidePanel` callback.
/// Default is a no-op so views that don't need the callback compile without injection.
private struct SuppressHidePanelKey: EnvironmentKey {
    /// No-op default so views compile without injection.
    /// Must be `@MainActor @Sendable` to match the closure injected by `AppDelegate.wrapEnv(_:)`.
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

/// RunBot-specific SwiftUI environment value extensions.
extension EnvironmentValues {
    /// Suppresses the popover's outside-click / app-switch hide behaviour for one
    /// cooperative-scheduler turn. Call this immediately **before** setting a
    /// `.sheet(item:)` binding to `nil` from an intentional dismiss (Cancel / Save).
    ///
    /// Injected by `AppDelegate.wrapEnv(_:)` via
    /// `.environment(\.suppressHidePanel, { lifecycleCoordinator.suppressHidePanel() })`.
    ///
    /// In views: `@Environment(\.suppressHidePanel) private var suppressHidePanel`
    var suppressHidePanel: @MainActor @Sendable () -> Void {
        get { self[SuppressHidePanelKey.self] }
        set { self[SuppressHidePanelKey.self] = newValue }
    }
}
