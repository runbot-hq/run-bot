// EnvironmentValues+RunBot.swift
// RunBot
//
// Custom SwiftUI environment keys used by the RunBot app target.
// All keys are defined here so they are discoverable in a single place.
import SwiftUI

// MARK: - suppressHidePanel

private struct SuppressHidePanelKey: EnvironmentKey {
    // Default is a no-op so views that don't need the callback compile without injection.
    // Must be @MainActor @Sendable to match the type injected by AppDelegate.wrapEnv(_:).
    // Swift 6 strict concurrency treats @MainActor @Sendable () -> Void and () -> Void
    // as distinct types — mismatching here causes a type error at the .environment(…) call site.
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

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
