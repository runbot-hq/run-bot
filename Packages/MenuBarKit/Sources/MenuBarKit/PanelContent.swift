// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the panel. Measurement happens via onGeometryChange
// on the content view — not via preferredContentSize KVO.
//
// WHY onGeometryChange (not preferredContentSize KVO):
//   RootEnvView is a concrete type. SwiftUI computes ideal height correctly
//   through a concrete type. onGeometryChange reports the actual rendered size
//   of the content after layout, which is the true measurement signal.
//
// SIZING CONTRACT (see SIZING PIPELINE in PanelController.swift for full detail):
//   sizingOptions = []          — pcs is unused, no feedback loop
//   three-edge AL pins          — no bottom pin, height is free
//   onGeometryChange            — sole measurement signal
//   limits.maxContentHeight     — @Observable, updated on open + screen change
//
// ❌ NEVER add .fixedSize() — not needed and breaks the capped scroll path.
// ❌ NEVER add a maxContentHeight stored property here — use limits.maxContentHeight.
// ❌ NEVER measure with GeometryReader — it sees window size, not content size.
// ❌ NEVER apply .glassEffect() here — glass cannot sample other glass.

import AppKit
import Observation
import SwiftUI

// MARK: - Limits

/// Live sizing and chrome state handed to the SwiftUI content.
///
/// Observable so that a change to `maxContentHeight` (recomputed on every open
/// and on screen-parameter changes) or to `arrowCenterX` (recomputed on every
/// frame apply) re-lays-out the content without rebuilding the hosting view.
@Observable
@MainActor
final class MBKPanelLimits {

    /// Maximum content height in points, recomputed live from the current screen.
    var maxContentHeight: CGFloat

    /// Arrow centre in window-local points, from the leading edge.
    var arrowCenterX: CGFloat

    init(maxContentHeight: CGFloat, arrowCenterX: CGFloat) {
        self.maxContentHeight = maxContentHeight
        self.arrowCenterX = arrowCenterX
    }
}

// MARK: - Root view

/// Root SwiftUI view of the panel: adopter content capped, padded, clipped.
///
/// No measurement happens here. preferredContentSize KVO on the hosting
/// controller is the sole sizing signal.
struct MBKPanelContentView<Content: View>: View {

    let limits: MBKPanelLimits
    let metrics: MBKPanelMetrics
    let content: Content
    /// Called when the content view's geometry changes (e.g. list grows/shrinks).
    let onSizeChange: (CGSize) -> Void

    private var bubble: MBKBubbleShape {
        MBKBubbleShape(
            arrowCenterX: limits.arrowCenterX,
            arrowHeight: metrics.arrowHeight,
            arrowWidth: metrics.arrowWidth,
            cornerRadius: metrics.cornerRadius
        )
    }

    var body: some View {
        content
            .padding(.top, metrics.arrowHeight)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
                mbkLog("PanelContent", "onGeometryChange fired size=\(size)")
                onSizeChange(size)
            }
            .clipShape(bubble)
    }
}
