// SparklineView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - SparklineView
/// A mini sparkline graph using Path: polyline stroke + gradient fill.
/// Color shifts green -> orange -> red based on the current value threshold.
/// Fill uses `.opacity(0.85)` top -> `.opacity(0.05)` bottom.
struct SparklineView: View {
    /// History ring buffer -- ordered oldest->newest, values 0-100.
    let history: [Double]
    /// Current value used to determine the theme color (0-100).
    let currentPct: Double
    /// Optional fixed tint that overrides the threshold-driven color.
    ///
    /// When `nil` (the default) the existing green/orange/red threshold
    /// behavior is preserved. Sidebar CPU and GPU pass a fixed tint so their
    /// sparkline color does not shift with load level.
    var tint: Color?

    /// Renders a gradient fill path and a stroke polyline scaled to the available geometry.
    var body: some View {
        GeometryReader { geo in
            layers(in: geo.size)
        }
        .background(Color.clear)
    }

    /// Stacks the gradient fill and stroke polyline for a given size.
    private func layers(in size: CGSize) -> some View {
        ZStack {
            fillPath(in: size)
                .fill(
                    LinearGradient(
                        colors: [resolvedColor.opacity(0.85), resolvedColor.opacity(0.05)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            strokePath(in: size)
                .stroke(resolvedColor, lineWidth: 1.5)
        }
    }

    /// Resolved color: explicit tint when provided, otherwise threshold-driven color.
    private var resolvedColor: Color { tint ?? themeColor }

    /// Accent color derived from the shared severity helper (green/orange/red).
    private var themeColor: Color {
        .rbMetricSeverity(percentage: currentPct)
    }

    /// Builds the open polyline `Path` used for the stroke layer.
    private func strokePath(in size: CGSize) -> Path {
        Path { path in
            let points = normalised(in: size)
            guard !points.isEmpty else { return }
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
        }
    }

    /// Builds the closed `Path` (dropping to the bottom edge) used for the gradient fill layer.
    private func fillPath(in size: CGSize) -> Path {
        Path { path in
            let points = normalised(in: size)
            guard !points.isEmpty, let lastPoint = points.last else { return }
            path.move(to: CGPoint(x: points[0].x, y: size.height))
            path.addLine(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: lastPoint.x, y: size.height))
            path.closeSubpath()
        }
    }

    /// Converts `history` values (0-100) to `CGPoint` coordinates scaled to `size`.
    private func normalised(in size: CGSize) -> [CGPoint] {
        guard history.count > 1 else {
            let val = history.first ?? 0
            let yPos = size.height - CGFloat(val / 100.0) * size.height
            return [CGPoint(x: 0, y: yPos), CGPoint(x: size.width, y: yPos)]
        }
        let count = history.count
        return history.enumerated().map { idx, val in
            let xPos = CGFloat(idx) / CGFloat(count - 1) * size.width
            let yPos = size.height - CGFloat(val / 100.0) * size.height
            return CGPoint(x: xPos, y: yPos)
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 12) {
        SparklineView(history: [10, 20, 35, 30, 55, 60, 45, 70, 65, 80], currentPct: 80)
            .frame(width: 60, height: 20)
        SparklineView(history: [40, 50, 60, 55, 65, 70, 68, 75, 80, 90], currentPct: 90)
            .frame(width: 60, height: 20)
        SparklineView(history: [5, 10, 8, 12, 9, 11, 10, 13, 10, 12], currentPct: 12)
            .frame(width: 60, height: 20)
    }
    .padding()
}
#endif
