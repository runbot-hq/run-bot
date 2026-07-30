// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline.
//
// HOW SIZING WORKS:
//
// 1. `MBKPanelContentView` wraps the adopter's content in an outer `.frame(.infinity)`
//    fill and an inner VStack. `onGeometryChange` is on the *inner* VStack.
// 2. The inner VStack measures the content's *natural* height before the outer fill
//    expands. So the signal is always "what the content wants", not "what the window is".
// 3. Every time natural height changes, `onSizeChange` fires and the controller calls
//    `applyMeasuredSize`, which clamps and resizes the window.
// 4. On first open, `layoutSubtreeIfNeeded()` forces SwiftUI to settle synchronously
//    so `onGeometryChange` fires before the panel is visible — no snap.
//
// WHY NOT preferredContentSize KVO:
//   Requires a concrete height proposal from AppKit before it populates.
//   With three-edge pins the hosting view collapses to zero pre-show,
//   so preferredContentSize is always (0,0) on open -> FALLBACK every time.
//
// ❌ NEVER measure with a GeometryReader — it sees the window size, not natural size.
// ❌ NEVER add .fixedSize() — breaks the capped scroll path.
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
        // Outer fill: expands to fill whatever size the window proposes.
        // Does NOT participate in measurement.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) {
                // Inner VStack: sized by content, not by window.
                // onGeometryChange lives on content so it re-fires when the
                // adopter's @Observable state changes and the subtree grows.
                VStack(spacing: 0) {
                    content
                        .padding(.top, metrics.arrowHeight)
                        .onGeometryChange(for: CGSize.self) { proxy in
                            proxy.size
                        } action: { newSize in
                            onSizeChange?(newSize)
                        }
                }
                .clipShape(bubble)
            }
    }
}
