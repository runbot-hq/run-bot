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
//   PR #6 wraps pendingRootView (a TYPED view, not AnyView) in
//   background(GeometryReader{...}) after applying .fixedSize().
//   .fixedSize() works because the view is typed — SwiftUI can see through
//   it to measure intrinsic size.
//
//   RunBot's shell.content is AnyView. .fixedSize() on AnyView is a no-op:
//   SwiftUI cannot look through type erasure. The fix must live INSIDE the
//   AnyView boundary — inside PanelContainerView — where the content is
//   typed and .fixedSize() is meaningful.
//
//   The working path: PanelContainerView's own background(GeometryReader)
//   sits INSIDE the AnyView boundary and measures PanelMainView's typed,
//   .fixedSize()-constrained intrinsic size correctly. It forwards via the
//   MBKSizeReporter environment key to NavigationShellView's onSizeChange.
//
// ID-KEYING — why .id(navigationID) is required:
//   shell.content is AnyView. When navigate() swaps it, SwiftUI sees
//   AnyView→AnyView — same static type — and diffs the internals rather
//   than destroying the subtree. Without .id(), the popover stays frozen.
//   Incrementing navigationID forces SwiftUI to destroy/recreate the child
//   subtree, guaranteeing onAppear fires with the new view's intrinsic size.
//   Identical to PR #6's .id(appState.route) on the Group switch.
//
// ARCHITECTURE:
//   NavigationShell     — @Observable object, lives on AppDelegate.
//                         Owns `content: AnyView` + `navigationID: Int`.
//   NavigationShellView — SwiftUI view, permanent NSHostingController root.
//                         Injects onSizeChange via MBKSizeReporter environment
//                         key so PanelContainerView's inner GeometryReader
//                         can forward size changes without a callback chain.
//
// RELATIONSHIP TO PanelContainerView:
//   PanelContainerView owns the active GeometryReader (inside AnyView boundary).
//   NavigationShellView injects the onSizeChange closure via environment.
//   PanelContainerView reads it and calls it from its background GeometryReader.
//
// ❌ NEVER replace NavigationShell as hostingController.rootView.
// ❌ NEVER add a GeometryReader outside the AnyView boundary — it sees proposed
//    size, not intrinsic size.
// ❌ NEVER call resizeAndRepositionPanel() directly from here — use onSizeChange.

/// @Observable slot holding the currently displayed content.
@Observable
@MainActor
final class NavigationShell {
    var content: AnyView
    var navigationID: Int = 0
    init(initial: AnyView) { self.content = initial }
}

// MARK: - Size reporter environment key

/// Environment key that carries the popover size-change callback from
/// NavigationShellView down to PanelContainerView's GeometryReader.
///
/// This is the bridge that replaces the impossible “.fixedSize() on AnyView”
/// approach: NavigationShellView sets this key; PanelContainerView reads it
/// and calls it from its background(GeometryReader), which IS inside the
/// AnyView boundary and measures typed, intrinsic content size correctly.
private struct SizeReporterKey: EnvironmentKey {
    static let defaultValue: ((CGSize) -> Void)? = nil
}

extension EnvironmentValues {
    var panelSizeReporter: ((CGSize) -> Void)? {
        get { self[SizeReporterKey.self] }
        set { self[SizeReporterKey.self] = newValue }
    }
}

// MARK: - NavigationShellView

/// Permanent SwiftUI root hosted by NSHostingController.
///
/// Injects `onSizeChange` into the environment via `panelSizeReporter` so
/// PanelContainerView’s inner GeometryReader (which IS inside the AnyView
/// boundary) can call it directly with the typed content’s intrinsic size.
struct NavigationShellView: View {
    @Environment(NavigationShell.self) private var shell
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        shell.content
            .id(shell.navigationID)
            .environment(\.panelSizeReporter, onSizeChange)
    }
}
