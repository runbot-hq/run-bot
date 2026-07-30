// DonutStatusView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - DonutStatusView
/// Replaces the PieProgressDot for the action row status indicator.
/// Three visual states:
/// - in_progress : animated rotating shimmer arc (blue) + arc trim from 0 to progress
/// - success     : full green circle stroke + checkmark SF Symbol
/// - failed      : full red circle stroke + xmark SF Symbol
/// - queued      : full yellow circle stroke + pause.fill SF Symbol
///
/// Animation contract:
/// - In-progress background ring uses `@State rotationAngle` driven by
///   `.linear(duration: 2).repeatForever(autoreverses: false)`.
/// - Progress arc uses `trim(from: 0, to: fraction)` animated with `.easeInOut`.
///
/// Do NOT remove the repeatForever animation -- it is the liveness indicator.
/// Do NOT start the rotation for non-.inProgress states -- it wastes CPU/GPU.
struct DonutStatusView: View {
    /// The workflow/job status this donut reflects.
    let status: RBStatus
    /// Progress fraction 0.0-1.0 for in-progress state; ignored for other states.
    var progress: Double = 0
    /// Outer ring diameter in points.
    var size: CGFloat = 16

    /// Current rotation angle for the shimmer ring; driven by `startRotationIfNeeded()`.
    @State private var rotationAngle: Double = 0
    /// Animated copy of `progress` updated via `withAnimation(.easeInOut)` for smooth arc trim.
    @State private var displayProgress: Double = 0

    /// Stroke width derived from the outer diameter (11% of `size`).
    private var strokeWidth: CGFloat { size * 0.11 }

    /// Creates a `DonutStatusView` with the given status, progress fraction, and diameter.
    /// - Parameters:
    ///   - status: The `RBStatus` driving the visual state of the ring.
    ///   - progress: Completion fraction 0.0–1.0; used only when `status == .inProgress`.
    ///   - size: Outer ring diameter in points. Defaults to `16`.
    init(status: RBStatus, progress: Double = 0, size: CGFloat = 16) {
        self.status = status
        self.progress = progress
        self.size = size
    }

    /// Renders the donut ring, switching between in-progress, terminal, and queued states.
    var body: some View {
        ZStack {
            switch status {
            case .inProgress:
                inProgressRing
            case .success:
                terminalRing(color: .rbSuccess, symbol: "checkmark")
            case .failed:
                terminalRing(color: .rbDanger, symbol: "xmark")
            case .queued:
                // pause.fill is blockier than checkmark/xmark; scale down slightly
                // to avoid clipping at small diameters (size ≤ 16). (#2355)
                terminalRing(color: .rbWarning, symbol: "pause.fill", symbolScale: 0.36)
            default:
                Circle()
                    .stroke(Color.rbTextTertiary.opacity(0.3), lineWidth: strokeWidth)
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            displayProgress = max(0, min(1, progress))
            startRotationIfNeeded()
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayProgress = max(0, min(1, progress))
            }
        }
        .onChange(of: status) { _, _ in startRotationIfNeeded() }
    }

    /// Starts the `repeatForever` rotation animation only when status is `.inProgress`.
    /// Safe to call multiple times -- SwiftUI deduplicates identical in-flight animations.
    private func startRotationIfNeeded() {
        guard status == .inProgress else { return }
        withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
            rotationAngle = 360
        }
    }

    /// Animated in-progress ring: faint shimmer background + blue arc trim.
    private var inProgressRing: some View {
        ZStack {
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [Color.rbBlue.opacity(0.0), Color.rbBlue.opacity(0.25)],
                        center: .center
                    ),
                    lineWidth: strokeWidth
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotationAngle))
            Circle()
                .trim(from: 0, to: CGFloat(displayProgress))
                .stroke(Color.rbBlue, style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
        }
    }

    /// Terminal state (success/failed/queued): solid colored ring + SF Symbol in the centre.
    /// - Parameters:
    ///   - color: The stroke and icon tint color (`.rbSuccess`, `.rbDanger`, or `.rbWarning`).
    ///   - symbol: The SF Symbol name to render in the centre of the ring.
    ///   - symbolScale: Font size multiplier relative to `size`. Defaults to `0.42`.
    ///     Pass a smaller value (e.g. `0.36`) for wider glyphs like `pause.fill`.
    private func terminalRing(color: Color, symbol: String, symbolScale: CGFloat = 0.42) -> some View {
        ZStack {
            Circle()
                .stroke(color, lineWidth: strokeWidth)
                .frame(width: size, height: size)
            Image(systemName: symbol)
                .font(.system(size: size * symbolScale, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

#if DEBUG
#Preview {
    HStack(spacing: 16) {
        DonutStatusView(status: .inProgress, progress: 0.6, size: 20)
        DonutStatusView(status: .success, size: 20)
        DonutStatusView(status: .failed, size: 20)
        DonutStatusView(status: .queued, size: 20)
        DonutStatusView(status: .queued, size: 16)
        DonutStatusView(status: .queued, size: 14)
    }
    .padding(20)
    .background(Color.rbSurface)
}
#endif
