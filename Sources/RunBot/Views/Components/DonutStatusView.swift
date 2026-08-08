// DonutStatusView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - DonutStatusView
/// Replaces the PieProgressDot for the action row status indicator.
/// Visual states:
/// - in_progress : animated rotating shimmer arc (blue) + arc trim from 0 to progress + centered play.fill symbol (Color.rbBlue)
/// - success     : full green circle stroke + checkmark SF Symbol
/// - failed      : full red circle stroke + xmark SF Symbol
/// - queued      : dim amber ring + revolving amber sweep + static pause.fill symbol
/// - skipped     : muted grey circle stroke + minus SF Symbol
///
/// Animation contract:
/// - In-progress background ring uses `@State rotationAngle` driven by
///   `.linear(duration: 2).repeatForever(autoreverses: false)`.
/// - Progress arc uses `trim(from: 0, to: fraction)` animated with `.easeInOut`.
/// - Queued uses a localized amber comet sweep with a bright 0.85-opacity head, a subtle glow,
///   and a 2.4-second linear revolution.
/// - Queued animation is owned by `QueuedDonutRing`.
/// - Reduce Motion removes the sweep and glow while preserving the amber base ring and pause symbol.
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
                QueuedDonutRing(size: size, strokeWidth: strokeWidth)
            case .skipped:
                // minus (no circle variant) pairs with the donut ring as the circular chrome.
                // rbTextTertiary.opacity(0.3) matches the ring stroke color — low emphasis,
                // clearly distinct from failed/queued. Default symbolScale 0.42 is correct
                // for the slim minus glyph.
                terminalRing(color: .rbTextTertiary.opacity(0.3), symbol: "minus")
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

    /// Animated in-progress ring: faint rotating shimmer background, blue progress arc,
    /// and a static centered play icon.
    ///
    /// - The shimmer and progress arc continue to animate as before.
    /// - The `play.fill` icon is static and does not participate in any animation.
    /// - Icon color is `Color.rbBlue` to match the progress arc.
    /// - Icon scale is `size * 0.36` (matching the `pause.fill` scale) to avoid
    ///   clipping at small donut sizes (10 pt job donut, 14 pt workflow donut).
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
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(Color.rbBlue)
                .accessibilityHidden(true)
        }
    }

    /// Terminal state (success/failed/queued/skipped): solid colored ring + SF Symbol in the centre.
    /// - Parameters:
    ///   - color: The stroke and icon tint color (`.rbSuccess`, `.rbDanger`, `.rbWarning`, or `.rbTextTertiary.opacity(0.3)`).
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

// MARK: - QueuedDonutRing

/// Queued donut treatment.
///
/// Renders a dim amber base ring, a slow revolving amber sweep when Reduce
/// Motion is disabled, and a static centered pause symbol.
private struct QueuedDonutRing: View {
    /// Outer ring diameter.
    let size: CGFloat
    /// Width of the base and sweep strokes.
    let strokeWidth: CGFloat

    /// Disables continuous rotation when the user requests reduced motion.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Rotation angle for the amber sweep.
    ///
    /// Lives inside this subview so leaving and re-entering queued creates
    /// a fresh animation lifecycle — no 360 → 360 dead-start, no visible snap.
    @State private var rotation: Double = 0

    /// Renders the base ring, optional revolving sweep, and static pause symbol.
    var body: some View {
        ZStack {
            baseRing
            if !reduceMotion {
                rotatingSweep
            }
            pauseSymbol
        }
        .frame(width: size, height: size)
    }

    /// Stronger dim amber ring visible behind the sweep, under Reduce Motion, and between
    /// brighter sweep portions at all donut sizes.
    private var baseRing: some View {
        Circle()
            .stroke(
                Color.rbWarning.opacity(0.35),
                lineWidth: strokeWidth
            )
    }

    /// Revolving localized amber comet sweep with a bright 0.85-opacity head, subtle tail,
    /// and a small amber glow. Rotates once every 2.4 seconds.
    ///
    /// `.onAppear` is attached here so the animation restarts automatically whenever
    /// Reduce Motion is turned off and this view re-enters the hierarchy.
    /// Reduce Motion removes the sweep and glow; the shadow belongs to this view and
    /// disappears with it automatically.
    private var rotatingSweep: some View {
        Circle()
            .stroke(
                AngularGradient(
                    gradient: Gradient(
                        stops: [
                            .init(color: Color.rbWarning.opacity(0), location: 0),
                            .init(color: Color.rbWarning.opacity(0.05), location: 0.55),
                            .init(color: Color.rbWarning.opacity(0.85), location: 0.84),
                            .init(color: Color.rbWarning.opacity(0), location: 1)
                        ]
                    ),
                    center: .center
                ),
                lineWidth: strokeWidth
            )
            .shadow(color: Color.rbWarning.opacity(0.40), radius: max(1, size * 0.08))
            .rotationEffect(.degrees(rotation))
            .onAppear {
                startRotation()
            }
    }

    /// Static queued-state pause symbol.
    private var pauseSymbol: some View {
        Image(systemName: "pause.fill")
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(Color.rbWarning)
            .accessibilityHidden(true)
    }

    /// Starts the queued sweep at 2.4 seconds per revolution (slower than active at 2 s).
    private func startRotation() {
        rotation = 0
        withAnimation(
            .linear(duration: 2.4)
                .repeatForever(autoreverses: false)
        ) {
            rotation = 360
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
        DonutStatusView(status: .skipped, size: 20)
        DonutStatusView(status: .skipped, size: 16)
        DonutStatusView(status: .skipped, size: 14)
    }
    .padding(20)
    .background(Color.rbSurface)
}
#endif
