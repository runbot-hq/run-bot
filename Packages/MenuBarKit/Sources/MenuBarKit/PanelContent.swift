// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline, and the panel's chrome.
//
// HOW SIZING WORKS — read this before touching anything here:
//
// `MBKPanelController` uses KVO on `hostingController.view.intrinsicContentSize`.
// AppKit invalidates intrinsic content size once per settled SwiftUI layout pass
// — reliable even before the window is on screen, no burst, no coalescer needed.
// 1. SwiftUI settles layout → `intrinsicContentSize` KVO fires once.
// 2. `MBKPanelController.applyMeasuredSize(_:)` subtracts the arrow strip,
//    clamps to the live screen cap, and calls `applyFrame(content:reason:)`.
// 3. Resizing the window re-proposes exactly that size to SwiftUI; a
//    `ScrollView` inside receives the capped height and scrolls instead of
//    overflowing.
//
// ❌ NEVER put a min/max *width* in this wrapper. It applies to every route the
//    adopter shows, so a fixed-width settings screen would be stretched to the
//    list's minimum width. Width belongs to the adopter's own views; MenuBarKit
//    caps only the height (the live screen fraction) and the screen width.
// ❌ NEVER remove `.fixedSize(horizontal: false, vertical: true)` from body.
//    It is what makes content report its natural height under the concrete AL
//    proposal so that short lists shrink the panel. Without it, .frame(maxHeight:)
//    fills the full window height for short content and the panel never shrinks.
// ❌ NEVER measure with a `GeometryReader`. A geometry reader sees the size we
//    already applied, not the size the content wants, so it cannot detect growth.
// ❌ NEVER apply `.glassEffect(...)` in this wrapper. Glass cannot sample other
//    glass: a SwiftUI glass ancestor silently flattens every
//    `GlassEffectContainer` in the adopter's content. The bubble is drawn by
//    `NSGlassEffectView` (direct panel.contentView) is below the hosting view
//    as a plain sibling — the same layering strategy NSPopover used for its chrome.
import AppKit
import Observation
import SwiftUI

// MARK: - Limits

/// Live chrome state handed to the SwiftUI content.
///
/// Observable so that a change to `arrowCenterX` (recomputed on every
/// frame apply) re-lays-out the content without rebuilding the hosting view.
/// `maxContentHeight` is no longer here — it is a plain scalar on
/// `MBKPanelController`, passed directly to `MBKPanelContentView` at
/// construction time. It does not need to be observed by SwiftUI: when it
/// changes (screen geometry change or new open) the hosting view's rootView
/// is already being rebuilt with the new value.
@Observable
@MainActor
final class MBKPanelLimits {

    /// Arrow centre in window-local points, from the leading edge.
    ///
    /// Written by `applyFrame(content:reason:)` from `MBKPanelGeometry.layout`.
    /// The controller is the only writer; the bubble shape is the only reader.
    var arrowCenterX: CGFloat

    /// Creates a limits object.
    /// - Parameter arrowCenterX: Initial arrow centre in window-local points.
    init(arrowCenterX: CGFloat) {
        self.arrowCenterX = arrowCenterX
    }
}

// MARK: - Root view

/// Root SwiftUI view of the panel: the adopter's content, clipped to the bubble.
///
/// The bubble *material* is not here — it is `NSGlassEffectView`, the direct
/// `panel.contentView`, sitting below this hosting view as a plain sibling.
/// This view only positions and clips, so the adopter's own Liquid Glass
/// renders with no glass ancestor above it.
struct MBKPanelContentView: View {

    /// Live arrow position.
    let limits: MBKPanelLimits

    /// Chrome metrics — arrow size and corner radius.
    let metrics: MBKPanelMetrics

    /// Maximum content height in points, passed as a plain scalar from the controller.
    let maxContentHeight: CGFloat

    /// The adopter's content.
    let content: AnyView

    /// Called by `onGeometryChange` every time SwiftUI's layout settles to a new
    /// size. The controller uses this to resize the window frame.
    var onSizeChange: ((CGSize) -> Void)?

    /// The current bubble silhouette, tracking the live arrow position.
    ///
    /// Used for clipping only. The same `arrowCenterX` also drives
    /// `NSGlassEffectView.cornerRadius` via `MBKPanelMetrics`, so the clip
    /// and the AppKit glass always agree.
    private var bubble: MBKBubbleShape {
        MBKBubbleShape(
            arrowCenterX: limits.arrowCenterX,
            arrowHeight: metrics.arrowHeight,
            arrowWidth: metrics.arrowWidth,
            cornerRadius: metrics.cornerRadius
        )
    }

    /// Caps the content height, insets it below the arrow, and clips to the bubble.
    ///
    /// Order matters:
    /// 1. `.fixedSize(horizontal: false, vertical: true)` makes content report its
    ///    natural (ideal) height regardless of the concrete AL proposal from the window.
    ///    Without this, `.frame(maxHeight:)` under a concrete proposal fills the full
    ///    window height for short content — the panel never shrinks.
    /// 2. `.frame(maxHeight: maxContentHeight, alignment: .top)` caps the natural height
    ///    at the screen fraction AND pins content to the top of that cap. Without
    ///    `alignment: .top`, SwiftUI centres content vertically inside the cap —
    ///    visible as the list floating in the middle of the panel while rows load.
    /// 3. `.padding(.top, metrics.arrowHeight)` adds the arrow strip above the content.
    /// 4. `.clipShape(bubble)` clips to the bubble silhouette.
    /// 5. `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` fills
    ///    the hosting view viewport and pins the already-top-aligned content to the
    ///    top of the window while the panel is resizing to its final size.
    /// 6. `onGeometryChange` fires with the final settled size — capped for tall content,
    ///    natural for short content — and drives the window frame.
    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: maxContentHeight, alignment: .top)
            .padding(.top, metrics.arrowHeight)
            .clipShape(bubble)
            .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                onSizeChange?(newSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
