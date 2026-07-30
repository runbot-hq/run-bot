// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline.
//
// HOW SIZING WORKS:
//
// 1. `MBKPanelContentView` measures the adopter's content with an inner VStack
//    that uses `.fixedSize` so it reports natural content height, not the
//    outer `.frame(.infinity)` fill size.
// 2. `onGeometryChange` is on the inner VStack — it re-fires whenever the
//    `AnyView` subtree changes size, even when the VStack's own identity
//    is stable. The `@Observable` state changes in the adopter cause SwiftUI
//    to re-render the subtree, which triggers a new geometry pass.
// 3. Every time natural height changes, `onSizeChange` fires and the controller
//    calls `applyMeasuredSize`, which clamps and resizes the window.
// 4. `maxContentHeight` is cached from the controller at construction time and
//    passed to `.frame(maxHeight:)` *before* `.fixedSize` — this gives a
//    `ScrollView` inside the content a real viewport proposal so it knows when
//    to scroll.
// 5. On first open, `layoutSubtreeIfNeeded()` forces SwiftUI to settle
//    synchronously so `onGeometryChange` fires before the panel is visible.
//
// WHY NOT preferredContentSize KVO:
//   Requires a concrete height proposal from AppKit before it populates.
//   With three-edge pins the hosting view collapses to zero pre-show,
//   so preferredContentSize is always (0,0) on open -> FALLBACK every time.
//
// ❌ NEVER measure with a GeometryReader — it sees the window size, not natural size.
// ❌ NEVER apply .glassEffect() here — glass cannot sample other glass.
import AppKit
import Observation
import SwiftUI

// MARK: - Limits

/// Live chrome state handed to the SwiftUI content.
@Observable
@MainActor
final class MBKPanelLimits {
    /// Arrow centre in window-local points, from the leading edge.
    var arrowCenterX: CGFloat
    init(arrowCenterX: CGFloat) {
        self.arrowCenterX = arrowCenterX
    }
}

// MARK: - Root view

/// Root SwiftUI view of the panel: adopter content clipped to the bubble.
struct MBKPanelContentView: View {

    let limits: MBKPanelLimits
    let metrics: MBKPanelMetrics
    let maxContentHeight: CGFloat
    let content: AnyView

    /// Called with the inner VStack's natural size whenever it changes.
    /// This is the sole measurement signal into the AppKit frame pipeline.
    var onSizeChange: ((CGSize) -> Void)?

    private var bubble: MBKBubbleShape {
        MBKBubbleShape(
            arrowCenterX: limits.arrowCenterX,
            arrowHeight: metrics.arrowHeight,
            arrowWidth: metrics.arrowWidth,
            cornerRadius: metrics.cornerRadius
        )
    }

    var body: some View {
        innerMeasured
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var innerMeasured: some View {
        VStack(spacing: 0) {
            // Arrow height placeholder — keeps the content below the arrow tip.
            Color.clear
                .frame(height: metrics.arrowHeight)
            content
                // Cap FIRST: gives ScrollView a real height proposal so it scrolls at the cap.
                .frame(maxHeight: maxContentHeight, alignment: .top)
                // THEN resolve to ideal height within that cap.
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
        // Measure here — sees natural content height, NOT the outer .infinity fill.
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { [self] newSize in
            mbkLog("MBKPanelContentView", "onGeometryChange -- naturalSize=(\(newSize.width),\(newSize.height))")
            onSizeChange?(newSize)
        }
        .clipShape(bubble)
    }
}
