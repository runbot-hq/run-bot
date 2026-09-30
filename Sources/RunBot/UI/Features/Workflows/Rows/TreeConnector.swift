// TreeConnector.swift
// RunBot

import SwiftUI

/// Vertical tree-connector line drawn to the left of a nested job or step row.
///
/// Renders a straight bar with an elbow arrow pointing at the row content.
/// For the last item in a group the bar stops at the elbow instead of
/// continuing to the bottom edge. Simplified from the menu-bar era's since-deleted
/// tree-line leader (issue #2881) — no vertical-overlap bridging is needed
/// because hierarchy rows are stacked without card padding between segments.
struct TreeConnector: View {
    /// Whether this is the last item in the group (bar stops at the elbow).
    let isLast: Bool
    /// Horizontal indent from the leading edge to the vertical bar centre.
    var indent: CGFloat = 7
    /// Colour of the connector lines.
    private let lineColor = Color.secondary.opacity(0.3)
    /// Width of the vertical bar stroke.
    private let barWidth: CGFloat = 1
    /// Horizontal reach of the elbow arm.
    private let elbowWidth: CGFloat = 10
    /// Size of the arrowhead at the elbow tip.
    private let arrowSize: CGFloat = 4

    /// Draws the vertical bar and elbow arrow using a `Canvas`.
    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let barX = indent
            var vertPath = Path()
            vertPath.move(to: CGPoint(x: barX, y: 0))
            vertPath.addLine(to: CGPoint(x: barX, y: isLast ? midY : size.height))
            ctx.stroke(vertPath, with: .color(lineColor), lineWidth: barWidth)
            let arrowTip = CGPoint(x: barX + elbowWidth, y: midY)
            var elbowPath = Path()
            elbowPath.move(to: CGPoint(x: barX, y: midY))
            elbowPath.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY))
            ctx.stroke(elbowPath, with: .color(lineColor), lineWidth: barWidth)
            var arrow = Path()
            arrow.move(to: arrowTip)
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY - arrowSize / 2))
            arrow.addLine(to: CGPoint(x: arrowTip.x - arrowSize, y: midY + arrowSize / 2))
            arrow.closeSubpath()
            ctx.fill(arrow, with: .color(lineColor))
        }
        .frame(width: indent + elbowWidth + 2)
    }
}
