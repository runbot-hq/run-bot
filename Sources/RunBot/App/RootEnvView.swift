// RootEnvView.swift
// RunBot

import MenuBarKit
import RunBotCore
import SwiftUI

// MARK: - RootEnvView

/// Named wrapper for the environment objects injected into the RootPanelView.
///
/// Replaces the `wrapEnv(_:)` helper's `AnyView` return type so that SwiftUI
/// sees a concrete type all the way through `MBKPanelContentView<RootEnvView>`.
/// This is load-bearing: `AnyView` erases the concrete type, which prevents
/// SwiftUI from computing ideal height through the type erasure barrier.
/// `preferredContentSize` KVO and `onGeometryChange` both work correctly
/// with a concrete type.
///
/// - Note: This view is owned by `AppDelegate` and passed to `MBKPanelController`
///   at construction time. It is not used elsewhere.
struct RootEnvView: View {

    /// Panel visibility state, passed through to the environment.
    let panelVisibilityState: PanelVisibilityState

    /// App domain state, passed through to the environment.
    let appState: AppState

    /// Overlay gate for sheet/file-picker tracking, passed through to the environment.
    let overlayGate: MBKOverlayGate

    /// Panel controller handle for remeasure, passed through to the environment.
    let panelControllerHandle: PanelControllerHandle

    /// The content view that receives the environment objects.
    let inner: RootPanelView

    /// The composed view body: passes environment objects to the inner view.
    var body: some View {
        inner
            .environment(panelVisibilityState)
            .environment(appState)
            .environment(overlayGate)
            .environment(panelControllerHandle)
    }
}
