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
//   PR #6 wraps pendingRootView in background(GeometryReader{...}) ONCE at
//   setupPopover() time — the GeometryReader lives at the NSHostingController
//   root and is NEVER replaced. Content changes flow through @Observable:
//   NavigationShell.content is mutated; NavigationShellView re-renders;
//   the GeometryReader sees the new intrinsic size and fires onChange.
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
// ARCHITECTURE:
//   NavigationShell   — @Observable object, lives on AppDelegate.
//                       Owns `content: AnyView` + `navigationID: Int`.
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                       Reads the slot via @Environment(NavigationShell.self).
//                       Applies .id(shell.navigationID) on content, then
//                       wraps it in background(GeometryReader{...}),
//                       calling onSizeChange on appear and on every change —
//                       identical to PR #6's applyContentSize wiring.
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
/// Applies `.id(shell.navigationID)` to force a destroy/recreate on every
/// `navigate()` call, then wraps the content in `background(GeometryReader{...})`
/// that calls `onSizeChange` on `.onAppear` and `.onChange(of: geo.size)`,
/// matching `PopoverController.setupPopover()` in runbot-hq/MenuBarKit PR #6.
///
/// ❌ NEVER use `.frame(width:height:)` or `.fixedSize()` here — this view
///    must propose unconstrained space to content so `fittingSize` is meaningful.
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
            // Matches PR #6: background GeometryReader reports intrinsic size
            // WITHOUT influencing content layout (a foreground/parent
            // GeometryReader would propose its own size back to content).
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { onSizeChange(geo.size) }
                        .onChange(of: geo.size) { _, newSize in onSizeChange(newSize) }
                }
            )
    }
}
