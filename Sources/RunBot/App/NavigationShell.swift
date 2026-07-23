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
// ARCHITECTURE:
//   NavigationShell   — @Observable object, lives on AppDelegate.
//                       Owns a single `content: AnyView` slot.
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                       Reads the slot via @Environment(NavigationShell.self).
//                       Wraps content in background(GeometryReader{...}),
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
/// Lives on `AppDelegate`. `navigate(to:)` writes `content`; `NavigationShellView`
/// reads it. The NSHostingController root is `NavigationShellView` — it is
/// created once in `setupPanel()` and never replaced.
@Observable
@MainActor
final class NavigationShell {
    /// The currently displayed content. Set by `AppDelegate.navigate(to:)`.
    var content: AnyView

    /// - Parameter initial: The first view to display (typically `mainView()`).
    init(initial: AnyView) {
        self.content = initial
    }
}

// MARK: - NavigationShellView

/// Permanent SwiftUI root hosted by `NSHostingController`.
///
/// Wraps whatever is in `NavigationShell.content` in a
/// `background(GeometryReader{...})` that calls `onSizeChange` on `.onAppear`
/// and `.onChange(of: geo.size)`, matching
/// `PopoverController.setupPopover()` in runbot-hq/MenuBarKit PR #6.
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
