// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the panel. Measurement happens via preferredContentSize
// KVO on the NSHostingController — not here. This file only defines the view
// hierarchy and the live chrome state.
//
// WHY NOT onGeometryChange:
//   rootView is stored as AnyView. SwiftUI cannot compute ideal height through
//   AnyView — it erases the concrete type. .fixedSize on an AnyView child
//   always resolves to 0. onGeometryChange therefore always reports only the
//   arrow placeholder height (metrics.arrowHeight), never the content height.
//   Making MBKPanelContentView generic does not fix this: Content resolves to
//   AnyView at the call site (NSHostingController<MBKPanelContentView<AnyView>>)
//   and SwiftUI still sees AnyView at layout time.
//
// WHY preferredContentSize KVO WORKS:
//   NSHostingController populates preferredContentSize at the AppKit/SwiftUI
//   bridge level under an unspecified height proposal. AnyView is not in that
//   call path. AppKit asks SwiftUI for the ideal size directly through the
//   renderer; the concrete list type is visible at that level.
//
// SIZING CONTRACT (see SIZING PIPELINE in PanelController.swift for full detail):
//   sizingOptions = .preferredContentSize  — pcs is live output
//   three-edge AL pins                     — top/leading/trailing only
//   KVO on preferredContentSize            — sole measurement signal
//   limits.maxContentHeight                — @Observable, updated on open + screen change
//
// ❌ NEVER add onGeometryChange here — AnyView erases ideal size.
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
            .frame(maxHeight: limits.maxContentHeight, alignment: .top)
            .padding(.top, metrics.arrowHeight)
            .clipShape(bubble)
    }
}
