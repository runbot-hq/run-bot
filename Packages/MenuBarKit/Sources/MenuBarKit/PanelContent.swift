// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline, and the panel's chrome.
//
// HOW SIZING WORKS — read this before touching anything here:
//
// 1. `MBKPanelController` creates an `NSHostingController<MBKPanelContentView>` with
//    `sizingOptions = []` and pins its view to the glass view on three edges
//    (leading, trailing, top — no bottom pin). AppKit therefore asks SwiftUI for the
//    ideal size under an *unspecified* height proposal.
// 2. `NSHostingController.preferredContentSize` is updated automatically by AppKit /
//    SwiftUI each time the ideal size changes. The controller KVO-observes this
//    property and forwards every non-trivial change to `applyMeasuredSize(_:)`.
// 3. `applyMeasuredSize` subtracts the arrow strip, clamps, and sets the window frame.
//    Resizing the window does NOT resize the three-edge-pinned hosting view vertically,
//    so SwiftUI keeps receiving an unspecified height proposal and `preferredContentSize`
//    reflects true content height, not the clamped window height.
// 4. On open: read `preferredContentSize` synchronously and call `applyMeasuredSize`
//    before `orderFront` so the first frame the user sees is always correct — no snap.
//
// ❌ NEVER put a min/max *width* in this wrapper.
// ❌ NEVER add `.fixedSize()` in this wrapper.
// ❌ NEVER measure with a `GeometryReader`.
// ❌ NEVER apply `.glassEffect(...)` in this wrapper.
import AppKit
import Observation
import SwiftUI

// MARK: - Limits

/// Live sizing and chrome state handed to the SwiftUI content.
///
/// Observable so that a change to `arrowCenterX` (recomputed on every frame apply)
/// re-lays-out the content without rebuilding the hosting controller.
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

    /// Insets the content below the arrow and clips to the bubble.
    ///
    /// Height capping is intentionally absent here — `applyMeasuredSize` is the
    /// sole cap, applied via the window frame. Keeping SwiftUI uncapped lets
    /// `preferredContentSize` always report the true content height.
    var body: some View {
        content
            .padding(.top, metrics.arrowHeight)
            .clipShape(bubble)
    }
}
