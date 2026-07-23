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
// FIX (matches PopoverController.setupPopover() in runbot-hq/MenuBarKit PR #6):
//   PR #6 wraps pendingRootView with background(GeometryReader{...}) BEFORE
//   type-erasing into AnyView and handing to NSHostingController. The
//   GeometryReader lives INSIDE the AnyView boundary and participates in
//   every layout pass triggered by content state changes.
//
//   Run-bot applies the same pattern in navigate(to:) and setupPanel():
//   each view is wrapped with the GeometryReader before being stored as
//   AnyView in NavigationShell.content. The GeometryReader is therefore
//   always inside the type-erased boundary — never outside it.
//
// WHY OUTSIDE-BOUNDARY FAILS:
//   If the GeometryReader wraps shell.content (an AnyView) from OUTSIDE,
//   NavigationShellView must re-render for the GeometryReader to fire.
//   But NavigationShellView only re-renders when shell.content itself
//   changes (i.e. on navigate() calls). @Observable state changes inside
//   PanelMainView — e.g. workflow rows loading async — do NOT cause
//   NavigationShellView to re-render. The GeometryReader sees no size
//   delta and onChange never fires. Popover stays frozen.
//
// ID-KEYING — why .id(navigationID) is required:
//   shell.content is AnyView. When navigate() swaps it, SwiftUI sees
//   AnyView→AnyView — same static type — and diffs the internals rather
//   than destroying the subtree. Without .id(), onAppear does not fire
//   on the new content's GeometryReader and the popover stays frozen at
//   the previous view's size.
//   Incrementing navigationID on every navigate() forces SwiftUI to destroy
//   and recreate the entire child subtree, guaranteeing onAppear fires with
//   the new content's actual intrinsic size — identical to PR #6's pattern
//   of .id(appState.route) on the Group switch.
//
// ARCHITECTURE:
//   NavigationShell     — @Observable object, lives on AppDelegate.
//                         Owns `content: AnyView` + `navigationID: Int`.
//                         content already has the GeometryReader baked in
//                         (added by navigate(to:) / setupPanel() before
//                         wrapping in AnyView).
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                         Reads the slot via @Environment(NavigationShell.self).
//                         Applies .id(shell.navigationID) to force
//                         destroy/recreate on every navigate() call.
//                         Does NOT own a GeometryReader — sizing is owned
//                         by the GeometryReader baked into each content view.
//
// RELATIONSHIP TO PanelContainerView:
//   PanelContainerView (dim overlay + sheet detection) is instantiated per
//   navigate() call and placed INTO the content slot — it is NOT the shell.
//   The GeometryReader wraps the content view before PanelContainerView,
//   so it sees the true intrinsic size of the inner content, not the
//   PanelContainerView chrome.
//
// ❌ NEVER replace NavigationShell as hostingController.rootView.
// ❌ NEVER add a GeometryReader to NavigationShellView — it would sit
//    outside the AnyView boundary and miss async state-driven size changes.
// ❌ NEVER call resizeAndRepositionPanel() directly from NavigationShellView.

/// @Observable slot holding the currently displayed content.
///
/// Lives on `AppDelegate`. `navigate(to:)` increments `navigationID` then
/// writes `content`; `NavigationShellView` reads both. The NSHostingController
/// root is `NavigationShellView` — it is created once in `setupPanel()` and
/// never replaced.
///
/// Each `content` value already has a `background(GeometryReader)` baked in,
/// added by `navigate(to:)` / `setupPanel()` before AnyView wrapping.
@Observable
@MainActor
final class NavigationShell {
    /// The currently displayed content. Set by `AppDelegate.navigate(to:)`.
    /// Always has a GeometryReader baked in — do not add another.
    var content: AnyView

    /// Monotonically incrementing counter. Incremented by `navigate(to:)` on
    /// every content swap. `NavigationShellView` applies `.id(navigationID)` to
    /// force SwiftUI to destroy/recreate the child subtree, guaranteeing
    /// `onAppear` fires with the new view's intrinsic size.
    ///
    /// ❌ NEVER reset to 0 — only ever increment.
    var navigationID: Int = 0

    /// - Parameter initial: The first view to display (typically `mainView()`).
    ///   Must already have the GeometryReader baked in — pass the result of
    ///   `AppDelegate.wrapWithSizeReporter(_:)`, not a bare view.
    init(initial: AnyView) {
        self.content = initial
    }
}

// MARK: - NavigationShellView

/// Permanent SwiftUI root hosted by `NSHostingController`.
///
/// Reads `shell.content` and applies `.id(shell.navigationID)` to force a
/// full destroy/recreate on every `navigate()` call — identical to PR #6's
/// `.id(appState.route)` pattern on the Group switch.
///
/// Does NOT own a GeometryReader. Each content value stored in
/// `NavigationShell.content` already has `background(GeometryReader)` baked
/// in by `navigate(to:)` / `setupPanel()`, so the GeometryReader is always
/// inside the AnyView boundary where it can observe async state-driven
/// layout changes.
///
/// ❌ NEVER add a GeometryReader here — it would sit outside the AnyView
///    boundary and only fire on navigate() calls, not on async data loads.
struct NavigationShellView: View {
    @Environment(NavigationShell.self) private var shell

    var body: some View {
        shell.content
            // .id() forces SwiftUI to destroy/recreate the subtree on every
            // navigate() call. Without it, AnyView→AnyView is the same static
            // type, SwiftUI diffs internals only, and the GeometryReader baked
            // into content sees no size change — popover stays frozen.
            // Matches PR #6's .id(appState.route) on the Group switch.
            .id(shell.navigationID)
    }
}
