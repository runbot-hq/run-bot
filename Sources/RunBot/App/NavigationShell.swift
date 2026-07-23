// NavigationShell.swift
// RunBot

import SwiftUI

// MARK: - NavigationShell
//
// Permanent root of the NSHostingController. Never replaced.
//
// WHY THIS EXISTS — the fixed-size regression:
//   navigate(to:) previously swapped hostingController.rootView, which
//   replaced the entire PanelContainerView shell — including its
//   GeometryReader. The new GeometryReader saw the same window size (no
//   delta from its perspective) and .onChange(of: geo.size) never fired.
//   The popover stayed locked at whatever size it had before navigation.
//
// HOW SIZING WORKS (matches PR #6 intent, adapted for AnyView boundary):
//   PR #6 places background(GeometryReader) on a TYPED view and it works
//   because .fixedSize() is meaningful on typed views. RunBot's
//   shell.content is AnyView — a GeometryReader outside that boundary
//   sees the proposed size from NSHostingController (the frozen
//   popover.contentSize), not intrinsic size. .fixedSize() on AnyView
//   is a no-op for the same reason.
//
//   SOLUTION: Use the environment to bridge the callback across the
//   AnyView boundary. NavigationShellView injects `onSizeChange` via
//   the `panelSizeReporter` environment key. PanelContainerView (inside
//   the boundary) reads it and calls it from its existing
//   background(GeometryReader), which measures PanelMainView's TYPED,
//   .fixedSize()-constrained intrinsic size correctly.
//
//   See EnvironmentValues+RunBot.swift for the key definition and full
//   rationale.
//
// ID-KEYING — why .id(navigationID) is still required:
//   shell.content is AnyView. When navigate() swaps it, SwiftUI diffs
//   AnyView→AnyView internals without destroying the subtree. Without
//   .id(), PanelContainerView isn’t recreated, its onAppear never fires,
//   and the GeometryReader doesn’t re-report size for the new content.
//   Incrementing navigationID forces full subtree recreation — identical
//   to PR #6’s .id(appState.route) on the Group switch.
//
// ARCHITECTURE:
//   NavigationShell     — @Observable object, lives on AppDelegate.
//                         Owns `content: AnyView` + `navigationID: Int`.
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                         Injects panelSizeReporter env key so
//                         PanelContainerView’s GeometryReader (inside
//                         AnyView boundary) calls resizeAndRepositionPanel.
//
// ❌ NEVER replace NavigationShell as hostingController.rootView.
// ❌ NEVER add a GeometryReader at NavigationShellView level — it is
//    outside the AnyView boundary and sees only the proposed (frozen) size.
// ❌ NEVER call resizeAndRepositionPanel() directly from here — use onSizeChange.

/// @Observable slot holding the currently displayed content.
@Observable
@MainActor
final class NavigationShell {
    /// The currently displayed content. Set by `AppDelegate.navigate(to:)`.
    var content: AnyView

    /// Monotonically incrementing counter. Incremented by `navigate(to:)` on
    /// every content swap. `NavigationShellView` applies `.id(navigationID)` to
    /// force SwiftUI to destroy/recreate the child subtree, guaranteeing
    /// PanelContainerView’s `onAppear` fires with the new view’s intrinsic size.
    ///
    /// ❌ NEVER reset to 0 — only ever increment.
    var navigationID: Int = 0

    /// - Parameter initial: The first view to display (typically `mainView()`).
    init(initial: AnyView) { self.content = initial }
}

// MARK: - NavigationShellView

/// Permanent SwiftUI root hosted by NSHostingController.
///
/// Injects `onSizeChange` into the environment via `panelSizeReporter` so
/// `PanelContainerView`’s inner GeometryReader (inside the AnyView boundary)
/// can call it with the typed content’s true intrinsic size.
///
/// Also applies `.id(shell.navigationID)` to force full subtree recreation on
/// every `navigate()` call, guaranteeing `onAppear` fires for the new content.
///
/// ❌ NEVER add a GeometryReader here — it is outside the AnyView boundary
///    and measures proposed size, not intrinsic size.
struct NavigationShellView: View {
    @Environment(NavigationShell.self) private var shell

    /// Forwarded from AppDelegate to resizeAndRepositionPanel(preferredSize:).
    /// Injected into the environment so PanelContainerView can call it
    /// from inside the AnyView boundary where typed intrinsic size is measurable.
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        shell.content
            // Force full subtree destroy/recreate on navigate() calls.
            // Without this, AnyView→AnyView is diffed, PanelContainerView
            // is reused, onAppear never fires, no resize for new content.
            .id(shell.navigationID)
            // Inject the size callback into the environment.
            // PanelContainerView reads panelSizeReporter and calls it from
            // its background(GeometryReader) — inside the AnyView boundary,
            // measuring typed intrinsic size, not the proposed (frozen) size.
            .environment(\.panelSizeReporter, onSizeChange)
    }
}
