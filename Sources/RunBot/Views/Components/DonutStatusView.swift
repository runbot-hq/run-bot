// DonutStatusView.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - DonutStatusView
/// Replaces the PieProgressDot for the action row status indicator.
/// Visual states:
/// - in_progress : oversized rotating `rbBlue` angular gradient through a stationary
///                 35% track / 100% arc mask, with a static centered play.fill symbol
/// - success     : full green circle stroke + checkmark SF Symbol
/// - failed      : full red circle stroke + xmark SF Symbol
/// - queued      : dim amber ring + revolving amber sweep + static pause.fill symbol
/// - skipped     : muted grey circle stroke + minus SF Symbol
///
/// Animation contract:
/// - In-progress uses `PhantomSweepRing`: one oversized `AngularGradient` (`rbBlue` 65%→100%)
///   rotates beneath a stationary alpha mask (track 35%, arc 100%). No solid underlayer.
///   Track reads approximately 23%–35%; arc reads 65%–100% — arc is always stronger.
/// - Source circle is expanded by `strokeWidth` on each side to cover the full stroke area.
/// - Only the gradient rotates; mask, progress geometry, and play symbol remain stationary.
/// - Gradient completes one clockwise revolution every 1.25 seconds.
/// - Reduce Motion shows a static ring: track at `rbBlue 24%`, arc at solid `rbBlue`.
/// - The play symbol remains static under both normal and reduced-motion conditions.
/// - Progress arc uses `trim(from: 0, to: fraction)` animated with `.easeInOut`.
/// - Queued uses a localized amber comet sweep with a bright 0.85-opacity head, a subtle glow,
///   and a 2.4-second linear revolution.
/// - Queued animation is owned by `QueuedDonutRing`.
/// - Reduce Motion removes the queued sweep and glow while preserving the amber base ring and pause symbol.
struct DonutStatusView: View {
    /// The workflow/job status this donut reflects.
    let status: RBStatus
    /// Progress fraction 0.0-1.0 for in-progress state; ignored for other states.
    var progress: Double = 0
    /// Outer ring diameter in points.
    var size: CGFloat = 16

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
        }
        .onChange(of: progress) { _, _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                displayProgress = max(0, min(1, progress))
            }
        }
    }

    /// Determinate progress ring with a phantom activity sweep and centered
    /// active-state symbol.
    private var inProgressRing: some View {
        ZStack {
            PhantomSweepRing(
                progress: displayProgress,
                size: size,
                strokeWidth: strokeWidth
            )

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

// MARK: - PhantomSweepRing

/// Determinate progress ring with a continuous phantom activity sweep.
///
/// Geometry remains stationary while an angular gradient rotates beneath an
/// alpha mask. The completed arc exposes the gradient at full intensity, and
/// the remaining track exposes it at 35% intensity.
private struct PhantomSweepRing: View {
    /// Current completion value, expected in the range `0...1`.
    let progress: Double
    /// Outer diameter of the ring.
    let size: CGFloat
    /// Width of the track and progress strokes.
    let strokeWidth: CGFloat

    /// Disables continuous rotation when requested by the user.
    @Environment(\.accessibilityReduceMotion)
    private var reduceMotion

    /// Current angular-gradient rotation.
    ///
    /// State belongs to this active-only component so entering the in-progress
    /// state creates a fresh animation lifecycle.
    @State private var rotation = 0.0

    /// Progress clamped to the supported trim range.
    private var normalizedProgress: CGFloat {
        CGFloat(max(0, min(1, progress)))
    }

    /// Renders the animated or static ring depending on Reduce Motion.
    var body: some View {
        Group {
            if reduceMotion {
                staticRing
            } else {
                animatedRing
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Rotating gradient source sized to cover the full stroked mask area.
    ///
    /// A filled `Circle` at `size` clips the outer half of the stroke rendered
    /// by the mask. Extending the source by `strokeWidth` on each side ensures
    /// the gradient reaches the outer edge of the mask stroke, restoring the
    /// same visual footprint as terminal rings.
    private var animatedRing: some View {
        ZStack {
            Circle()
                .fill(sweepGradient)
                .frame(
                    width: size + strokeWidth * 2,
                    height: size + strokeWidth * 2
                )
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: size, height: size)
        .mask { ringMask }
        .onAppear { startAnimation() }
    }

    /// Subtle RunBot-blue activity sweep.
    ///
    /// The progress arc varies from 65% to 100% intensity. Through the
    /// 35% track mask, the same gradient appears at approximately 23% to 35%.
    /// This guarantees that the completed arc is always visually stronger than
    /// the unfinished track. Matching start/end stops at 65% removes the wrap seam.
    private var sweepGradient: AngularGradient {
        AngularGradient(
            stops: [
                .init(color: Color.rbBlue.opacity(0.65), location: 0.00),
                .init(color: Color.rbBlue.opacity(0.65), location: 0.55),
                .init(color: Color.rbBlue.opacity(0.78), location: 0.80),
                .init(color: Color.rbBlue, location: 0.94),
                .init(color: Color.rbBlue.opacity(0.65), location: 1.00)
            ],
            center: .center
        )
    }

    /// Static alpha mask controlling the visibility of the rotating gradient.
    private var ringMask: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.35), lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: normalizedProgress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }

    /// Reduced-motion fallback preserving accurate determinate progress.
    private var staticRing: some View {
        ZStack {
            Circle()
                .stroke(Color.rbBlue.opacity(0.24), lineWidth: strokeWidth)
            Circle()
                .trim(from: 0, to: normalizedProgress)
                .stroke(
                    Color.rbBlue,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
        }
    }

    /// Starts one clockwise revolution every 1.25 seconds.
    private func startAnimation() {
        rotation = 0
        withAnimation(
            .linear(duration: 1.25)
                .repeatForever(autoreverses: false)
        ) {
            rotation = 360
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
