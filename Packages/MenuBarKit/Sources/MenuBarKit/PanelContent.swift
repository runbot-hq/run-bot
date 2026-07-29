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
// ❌ NEVER add `.fixedSize(vertical: true)` or `.frame(maxHeight:)` in this
//    wrapper. The hosting view has no bottom AL pin, so SwiftUI receives an
//    unspecified height proposal. Under an unspecified proposal, `.frame(maxHeight:)`
//    is a no-op (it only reduces a *parent-proposed* height) and `.fixedSize`
//    causes SwiftUI to pass the content's ideal height straight through, defeating
//    the cap entirely. The AppKit pipeline in `applyMeasuredSize` → `clampContent`
//    is the one and only cap; the SwiftUI layer must not interfere with it.
//    See issue #2339 for the full analysis.
// ❌ NEVER put a min/max *width* in this wrapper. It applies to every route the
//    adopter shows, so a fixed-width settings screen would be stretched to the
//    list's minimum width. Width belongs to the adopter's own views; MenuBarKit
//    caps only the height (the live screen fraction) and the screen width.
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

    /// Insets content below the arrow, clips to the bubble, reports settled size.
    ///
    /// Sizing is owned entirely by the AppKit pipeline:
    /// 1. `onGeometryChange` fires with the content's ideal settled size.
    /// 2. `applyMeasuredSize` clamps it to the live screen cap.
    /// 3. `applyFrame` resizes the window to the clamped size.
    /// 4. The window re-proposes the capped height to SwiftUI on the next pass.
    /// 5. A `ScrollView` inside `content` receives the cap as a concrete proposal
    ///    and scrolls rather than overflowing.
    ///
    /// `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)` fills
    /// the hosting-view viewport and pins content to the top during the brief
    /// interval between the initial (stale fittingSize) WRITE and the settled
    /// onGeometryChange WRITE, preventing content from floating to centre.
    var body: some View {
        content
            .padding(.top, metrics.arrowHeight)
            .clipShape(bubble)
            .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                onSizeChange?(newSize)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
