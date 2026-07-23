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

// MARK: - panelSizeReporter

/// Environment key that carries the popover size-change callback from
/// NavigationShellView down to PanelContainerView’s GeometryReader.
///
/// WHY THIS EXISTS — the AnyView boundary problem:
///   NavigationShellView holds shell.content as AnyView. Any GeometryReader
///   placed OUTSIDE that AnyView boundary (at NavigationShellView level) sees
///   the proposed size from NSHostingController — which echoes the current
///   popover.contentSize (frozen). .fixedSize() on AnyView is also a no-op:
///   SwiftUI cannot look through type erasure to measure intrinsic size.
///
///   The correct measurement point is INSIDE PanelContainerView, where the
///   content is typed and .fixedSize(horizontal:true,vertical:false) on
///   PanelMainView is already applied. PanelContainerView’s existing
///   background(GeometryReader) measures that typed intrinsic size correctly.
///
///   This key is the bridge: NavigationShellView injects `onSizeChange` into
///   the environment; PanelContainerView reads it and calls it from its
///   existing GeometryReader, which IS inside the AnyView boundary.
///
/// Injected by `NavigationShellView` via
///   `.environment(\.panelSizeReporter, onSizeChange)`.
///
/// Read by `PanelContainerView` via
///   `@Environment(\.panelSizeReporter) private var panelSizeReporter`.
///
/// Default is nil so views that don’t need sizing compile without injection.
private struct PanelSizeReporterKey: EnvironmentKey {
    static let defaultValue: ((CGSize) -> Void)? = nil
}

extension EnvironmentValues {
    /// The popover size-reporter callback. Set by NavigationShellView, consumed
    /// by PanelContainerView’s GeometryReader. Nil when not injected.
    var panelSizeReporter: ((CGSize) -> Void)? {
        get { self[PanelSizeReporterKey.self] }
        set { self[PanelSizeReporterKey.self] = newValue }
    }
}
