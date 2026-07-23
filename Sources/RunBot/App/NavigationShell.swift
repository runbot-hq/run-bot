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
//   PR #6 wraps pendingRootView in .fixedSize() THEN background(GeometryReader).
//   .fixedSize() forces SwiftUI to measure the view's intrinsic size regardless
//   of the proposed space from NSHostingController. The GeometryReader in the
//   background then sees that intrinsic size and fires onChange whenever content
//   grows — e.g. when workflow rows load after the panel opens.
//
//   WITHOUT .fixedSize(): NSHostingController (sizingOptions=[]) proposes the
//   current popover.contentSize as available space. The background GeometryReader
//   sees the proposed size (not intrinsic), so when content grows the proposed
//   size doesn't change → onChange never fires → popover stays frozen.
//
// ID-KEYING — why .id(navigationID) is required:
//   shell.content is AnyView. When navigate() swaps it, SwiftUI sees
//   AnyView→AnyView — same static type — and diffs the internals rather
//   than destroying the subtree. The GeometryReader in the background sees
//   the SAME proposed size (current window size, unchanged) and .onChange
//   never fires. Without .id(), the popover stays frozen at whatever size
//   it had before the navigate() call.
//   Incrementing navigationID on every navigate() forces SwiftUI to destroy
//   and recreate the entire child subtree, guaranteeing onAppear fires with
//   the new content's actual intrinsic size — identical to PR #6's pattern
//   of .id(appState.route) on the Group switch.
//
// MODIFIER ORDER (critical — do not reorder):
//   shell.content
//     .id(navigationID)           — destroy/recreate subtree on navigate()
//     .fixedSize()                — report intrinsic size regardless of proposal
//     .background(GeometryReader) — measures intrinsic size, fires onChange
//
//   .fixedSize() MUST be between .id() and .background().
//   If placed after .background(), the GeometryReader still sees the proposed
//   size, not the intrinsic size.
//
// SCROLLVIEW SAFETY:
//   PanelMainView's inner ScrollView uses .frame(maxHeight: screenScrollMaxHeight)
//   — a concrete pixel value (~80% of screen height). .fixedSize() proposes
//   unconstrained space to the ScrollView; the maxHeight cap is enforced by
//   the ScrollView itself and is NOT overridden. The cap holds correctly.
//
// ARCHITECTURE:
//   NavigationShell   — @Observable object, lives on AppDelegate.
//                       Owns `content: AnyView` + `navigationID: Int`.
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                       Reads the slot via @Environment(NavigationShell.self).
//                       Applies .id(navigationID), .fixedSize(), then
//                       background(GeometryReader{...}) — calling onSizeChange
//                       on appear and on every change. Identical to PR #6's
//                       pendingRootView.fixedSize().background(GeometryReader)
//                       pattern in setupPopover().
//
// RELATIONSHIP TO PanelContainerView:
//   PanelContainerView (dim overlay + sheet detection) is instantiated per
//   navigate() call and placed INTO the content slot — it is NOT the shell.
//   The GeometryReader that drives popover sizing lives at the shell level,
//   ABOVE PanelContainerView, so content swaps never remove it.
//
// ❌ NEVER replace NavigationShell as hostingController.rootView.
// ❌ NEVER add a second GeometryReader-based size observer inside this file.
// ❌ NEVER call resizeAndRepositionPanel() directly from here — use onSizeChange.
// ❌ NEVER remove .fixedSize() — without it the GeometryReader measures the
//    proposed size (frozen popover.contentSize) not the intrinsic size.
// ❌ NEVER move .fixedSize() after .background() — order is critical.

/// @Observable slot holding the currently displayed content.
///
/// Lives on `AppDelegate`. `navigate(to:)` increments `navigationID` then
/// writes `content`; `NavigationShellView` reads both. The NSHostingController
/// root is `NavigationShellView` — it is created once in `setupPanel()` and
/// never replaced.
@Observable
@MainActor
final class NavigationShell {
    /// The currently displayed content. Set by `AppDelegate.navigate(to:)`.
    var content: AnyView

    /// Monotonically incrementing counter. Incremented by `navigate(to:)` on
    /// every content swap. `NavigationShellView` applies `.id(navigationID)` to
    /// force SwiftUI to destroy/recreate the child subtree, guaranteeing
    /// `onAppear` fires with the new view's intrinsic size.
    ///
    /// ❌ NEVER reset to 0 — only ever increment.
    var navigationID: Int = 0

    /// - Parameter initial: The first view to display (typically `mainView()`).
    init(initial: AnyView) {
        self.content = initial
    }
}

// MARK: - NavigationShellView

/// Permanent SwiftUI root hosted by `NSHostingController`.
///
/// Applies `.id(navigationID)`, `.fixedSize()`, then `background(GeometryReader)`
/// that calls `onSizeChange` on `.onAppear` and `.onChange(of: geo.size)`.
///
/// This matches `PopoverController.setupPopover()` in runbot-hq/MenuBarKit PR #6
/// exactly: `pendingRootView.fixedSize().background(GeometryReader{...})`.
///
/// `.fixedSize()` is required so the GeometryReader measures the content's
/// INTRINSIC size rather than the proposed size from NSHostingController.
/// See MODIFIER ORDER in the MARK comment above.
struct NavigationShellView: View {
    @Environment(NavigationShell.self) private var shell

    /// Forwarded from AppDelegate to resizeAndRepositionPanel(preferredSize:).
    /// Set once at setup time — captured by the NSHostingController closure.
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        shell.content
            // .id() forces SwiftUI to destroy/recreate the subtree on every
            // navigate() call. Without it, AnyView→AnyView is the same static
            // type, SwiftUI diffs internals only, and the background
            // GeometryReader sees no size change — popover stays frozen.
            // Matches PR #6's .id(appState.route) on the Group switch.
            .id(shell.navigationID)
            // .fixedSize() — REQUIRED. Matches PR #6's pattern.
            // Forces SwiftUI to measure intrinsic size regardless of the space
            // proposed by NSHostingController (which echoes popover.contentSize
            // when sizingOptions = []). Without this the GeometryReader sees
            // the proposed size (frozen after first layout) and onChange never
            // fires as content grows.
            // ❌ NEVER remove. ❌ NEVER move after .background().
            .fixedSize()
            // background GeometryReader reports intrinsic size WITHOUT
            // influencing content layout. Fires onSizeChange on appear and
            // on every subsequent size change (workflow rows loading, etc.).
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { onSizeChange(geo.size) }
                        .onChange(of: geo.size) { _, newSize in onSizeChange(newSize) }
                }
            )
    }
}
