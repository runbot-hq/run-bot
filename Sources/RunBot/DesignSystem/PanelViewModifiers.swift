// PanelViewModifiers.swift
// RunBot
import RunBotCore
import SwiftUI

// MARK: - GlassCard
/// Centralised Liquid Glass card modifier.
/// On macOS 26+ uses `.glassEffect(.regular)` — passive containers must NOT
/// use `.interactive()`. The LiquidGlassReference guide restricts `.interactive()`
/// to tappable controls (buttons, icons) only. Applying it to a passive container
/// activates scaling/shimmer on the entire card surface including non-interactive
/// children, which is semantically wrong and wastes GPU compositing budget.
/// Tappable rows handle interactivity at the contentShape/button level via GlassButton.
/// On older OSes falls back to `.ultraThinMaterial` + a subtle stroke overlay.
///
/// All phases of the Liquid Glass adoption (Phase 3–7) must use `.glassCard()`
/// instead of calling `.glassEffect()` or `.ultraThinMaterial` directly on
/// card containers.
///
/// ❌ Do NOT convert `StatPill` to `GlassCard` — it is a capsule-shaped inline
/// pill, not a card container. Use `StatPillBackground` instead.
/// ❌ Do NOT add `.interactive()` back to GlassCard — see #963.
struct GlassCard: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat
    /// Opacity of the fallback stroke border. Defaults to 0.15; use 0.25 for sections.
    var strokeOpacity: Double

    /// Creates a `GlassCard` modifier with custom corner radius and stroke opacity.
    init(cornerRadius: CGFloat = RBRadius.card, strokeOpacity: Double = 0.15) {
        self.cornerRadius = cornerRadius
        self.strokeOpacity = strokeOpacity
    }

    /// Applies the glass card effect to the given content view.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
                )
        } else {
            materialFallback(content: content)
        }
    }

    /// Returns the pre-macOS-26 material + stroke fallback for the given content.
    private func materialFallback(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 0.5)
            )
    }
}

// MARK: - GlassSection
/// Prominent Liquid Glass modifier for section headers and containers.
/// Delegates to `GlassCard` with stronger stroke opacity (0.25).
struct GlassSection: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.card`.
    var cornerRadius: CGFloat

    /// Creates a `GlassSection` modifier with the given corner radius.
    init(cornerRadius: CGFloat = RBRadius.card) { self.cornerRadius = cornerRadius }

    /// Applies a prominent glass section effect to the given content view.
    func body(content: Content) -> some View {
        content.modifier(GlassCard(cornerRadius: cornerRadius, strokeOpacity: 0.25))
    }
}

// MARK: - GlassButton
/// Liquid Glass interactive button modifier.
/// On macOS 26+ applies `.glassEffect(.regular.interactive())` directly to content.
/// On older OSes passes through unstyled.
///
/// ⚠️ Call sites that group multiple `GlassButton` instances side-by-side MUST wrap
/// them in a shared `GlassEffectContainer` so sibling buttons share a single
/// CABackdropLayer sampling region — enabling morphing and avoiding redundant
/// GPU compositing passes. Do NOT embed a `GlassEffectContainer` inside this modifier.
///
/// ❌ Do NOT call `.glassEffect(.regular.interactive())` directly on buttons.
struct GlassButton: ViewModifier {
    /// Corner radius applied to the rounded rectangle shape. Defaults to `RBRadius.small`.
    var cornerRadius: CGFloat

    /// Creates a `GlassButton` modifier with the given corner radius.
    init(cornerRadius: CGFloat = RBRadius.small) { self.cornerRadius = cornerRadius }

    /// Applies the interactive glass button effect to the given content view.
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
        }
    }
}

// MARK: - StatPillBackground
/// Background modifier for `StatPill` and `RunnerMetricsBadge` capsule pills.
///
/// macOS 26+: identical architecture to `DiskPillBadge`:
///   `Color.rbGlassNeutral.opacity(0.15)` — black in light appearance, white in
///   dark appearance — bleeds through the glass refractive layer and defines the
///   pill edge visually in both modes, exactly as coloured pills do.
///   `Color.primary` was wrong — it resolves to near-black in dark mode,
///   making the tint invisible and leaving the glass nothing to refract.
///
/// The call site MUST wrap `RunnerMetricsBadge` in its OWN `GlassEffectContainer`
/// (separate from the card container) — same pattern as `DiskPillBadge` in
/// `HeaderStatsBar` and `StatusBadge` in `metaTrailing`.
///
/// macOS < 26: `.ultraThinMaterial` in a `Capsule()` (unchanged).
///
/// ❌ Do NOT revert tint to `Color.primary` — it is near-black in dark mode.
struct StatPillBackground: ViewModifier {
    /// Applies the stat pill background: glass capsule on macOS 26+, `.ultraThinMaterial` capsule on older OSes.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbGlassNeutral.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

// MARK: - StatusBadgeBackground
/// Colour tint + glass — identical pattern to DiskPillBadge.
/// Call site MUST wrap in GlassEffectContainer.
struct StatusBadgeBackground: ViewModifier {
    /// The accent colour used for the tint and (pre-macOS-26) stroke border.
    let color: Color

    /// Applies the status badge background: coloured glass capsule on macOS 26+, tinted fill + hairline stroke on older OSes.
    /// The pre-26 branch was intentionally upgraded from a bare stroke to a filled capsule (matching DiskPillBadge)
    /// for visual consistency with the Liquid Glass design language rollout.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(color.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(color.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 0.5))
        }
    }
}

// MARK: - BranchTagPillBackground
/// Background modifier for `BranchTagPill` capsule pills.
/// macOS 26+: accent colour tint + `.glassEffect(.regular, in: Capsule())`.
/// macOS < 26: accent colour stroke border.
struct BranchTagPillBackground: ViewModifier {
    /// Applies the branch tag pill background: accent glass capsule on macOS 26+, accent stroke capsule on older OSes.
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .background(Color.rbAccent.opacity(0.15), in: Capsule())
                .glassEffect(.regular, in: Capsule())
        } else {
            content.background(Capsule().strokeBorder(Color.rbAccent.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - CardRowModifier
/// Surface-fill modifier for card rows inside a scrollable list.
/// Uses `Color.rbSurfaceElevated` when `elevated` is true, otherwise `Color.rbSurface`.
///
/// ❌ NEVER apply `.glassEffect` here.
/// Apple HIG: glass effects must not be applied to scrollable list content —
/// they break CABackdropLayer sampling and cause visual artefacts during scroll.
/// If you are an agent or human, DO NOT REMOVE THIS COMMENT.
///
/// WHY .id(colorScheme) — FULL EXPLANATION (fix for #2098 bug 2):
///
/// The surface tokens (`rbSurface`, `rbSurfaceElevated`) are backed by a dynamic
/// `NSColor` closure that correctly re-fires when the system appearance changes.
/// You might expect this to be sufficient — but it is not, for a subtle reason:
///
/// SwiftUI's `.fill()` modifier has no `colorScheme` dependency of its own. When
/// the NSColor closure fires, AppKit resolves the new color, but SwiftUI's diffing
/// engine sees no change in the view tree — the `Color` value in `.fill()` is
/// structurally identical before and after the switch. The old fill layer sits in
/// the render tree, stale, displaying the pre-switch color.
///
/// `.id(colorScheme)` gives SwiftUI an explicit identity dependency on the current
/// appearance. When `colorScheme` changes, the node's identity changes, which forces
/// SwiftUI to **destroy and recreate** the background sublayer entirely — picking up
/// the correct resolved color from the NSColor closure in the process.
///
/// IMPORTANT: `.id()` is applied to the `RoundedRectangle` shape, NOT to `content`.
/// This is correct and intentional. Only the background sublayer is torn down;
/// the card content (text, icons, subviews) is unaffected. Applying `.id()` to
/// `content` would destroy and recreate the entire card subtree, which is wrong.
///
/// WORKAROUND NOTE: `.id(colorScheme)` is a workaround for current SwiftUI behaviour
/// (as of macOS 26 / SwiftUI 6). SwiftUI's `.fill()` does not currently track dynamic
/// NSColor closures as a render dependency. If a future SDK version adds that tracking,
/// this `.id()` becomes redundant (causing a spurious node teardown on every mode switch
/// with no visual benefit). It is safe to remove if SwiftUI ever resolves dynamic NSColor
/// lazily with a proper colorScheme dependency — verify with a light↔dark toggle test.
///
/// STROKE COVERAGE NOTE: `.id(colorScheme)` is applied only to the fill shape here.
/// Any call site that adds a separate stroke overlay using an adaptive token would need
/// the same `.id()` treatment on that overlay shape. As of this writing, `cardRow()` is
/// the only consumer of `CardRowModifier` and it has no stroke overlay — so no additional
/// `.id()` coverage is required. If a stroke is added in future, apply `.id(colorScheme)`
/// to the stroke shape as well.
///
/// Teardown cost for a low-frequency mode-switch event is negligible.
struct CardRowModifier: ViewModifier {
    /// When `true`, uses the elevated surface colour token instead of the base surface.
    var elevated: Bool = false

    /// The current color scheme, used to force background node recreation on appearance change.
    @Environment(\.colorScheme) private var colorScheme

    /// Applies the card row background to the given content view.
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: RBRadius.card, style: .continuous)
                .fill(elevated ? Color.rbSurfaceElevated : Color.rbSurface)
                .id(colorScheme) // forces background node recreation on appearance change — see block comment above
        )
    }
}

// MARK: - View extensions
/// Convenience modifiers for applying design-system glass effects and backgrounds.
extension View {
    /// Applies the `GlassCard` modifier with the given corner radius.
    func glassCard(cornerRadius: CGFloat = RBRadius.card) -> some View { modifier(GlassCard(cornerRadius: cornerRadius)) }

    /// Applies the `GlassSection` modifier with the given corner radius.
    func glassSection(cornerRadius: CGFloat = RBRadius.card) -> some View { modifier(GlassSection(cornerRadius: cornerRadius)) }

    /// Applies the `GlassButton` modifier with the given corner radius.
    func glassButton(cornerRadius: CGFloat = RBRadius.small) -> some View { modifier(GlassButton(cornerRadius: cornerRadius)) }

    /// Applies the `StatPillBackground` modifier.
    /// ⚠️ Call site MUST wrap RunnerMetricsBadge in its OWN GlassEffectContainer on macOS 26+.
    func statPillBackground() -> some View { modifier(StatPillBackground()) }

    /// Applies the `StatusBadgeBackground` modifier with the given colour.
    /// ⚠️ Call site MUST wrap badge in a GlassEffectContainer on macOS 26+.
    func statusBadgeBackground(color: Color) -> some View { modifier(StatusBadgeBackground(color: color)) }

    /// Applies the `BranchTagPillBackground` modifier.
    func branchTagPillBackground() -> some View { modifier(BranchTagPillBackground()) }

    /// Applies the `CardRowModifier`.
    /// ❌ NEVER add `.glassEffect` to this modifier.
    func cardRow(elevated: Bool = false) -> some View { modifier(CardRowModifier(elevated: elevated)) }
}

// MARK: - StatPill
/// Compact pill showing a label + value (e.g. "CPU 3.2%").
/// ❌ Do NOT convert to GlassCard — capsule-shaped pill, not a card container.
struct StatPill: View {
    /// Short label displayed to the left of the value (e.g. "CPU", "MEM").
    let label: String
    /// Formatted value string displayed to the right of the label (e.g. "3.2%").
    let value: String

    /// Renders the label–value pair inside a `statPillBackground` capsule.
    var body: some View {
        HStack(spacing: 3) {
            Text(label).font(RBFont.statLabel).foregroundColor(.secondary)
            Text(value).font(RBFont.statValue).foregroundColor(.primary).monospacedDigit()
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .statPillBackground()
    }
}

// MARK: - StatusBadge
/// Capsule badge for action-row trailing area.
/// ⚠️ Must be wrapped in a `GlassEffectContainer` at the call site for correct glass rendering.
struct StatusBadge: View {
    /// The status whose colour is applied to the badge text and background tint.
    let status: RBStatus
    /// Short uppercased label displayed inside the badge (e.g. "IN PROGRESS").
    let text: String

    /// Renders the status text inside a `statusBadgeBackground` capsule.
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(status.color)
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .statusBadgeBackground(color: status.color)
    }
}

// MARK: - BranchTagPill
/// Inline pill displaying a git branch or tag name.
struct BranchTagPill: View { // periphery:ignore — used dynamically inside ActionRowView.rowContent
    /// The branch or tag name to display.
    let name: String

    /// Renders the branch icon and truncated name inside a `branchTagPillBackground` capsule.
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .medium))
            Text(name).font(.system(size: 10, weight: .medium)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundColor(Color.rbAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .branchTagPillBackground()
    }
}

// MARK: - Previews
#if DEBUG
#Preview("GlassCard") {
    VStack(spacing: 12) {
        Text("Glass Card").padding().glassCard()
        Text("Glass Card r=10").padding().glassCard(cornerRadius: 10)
    }.padding()
}
#Preview("GlassSection") { Text("Section Header").padding().glassSection().padding() }
#Preview("GlassButton") {
    Button(action: { /* Preview only — no action needed in a static preview. */ }) { Text("Re-run").font(.caption).padding(.horizontal, 8).padding(.vertical, 4) }
        .buttonStyle(.plain).glassButton().padding()
}
#Preview("StatPill") {
    HStack(spacing: 8) { StatPill(label: "CPU", value: "3.6%"); StatPill(label: "MEM", value: "0.2%") }.padding()
}
#Preview("StatusBadge") {
    VStack(spacing: 8) {
        StatusBadge(status: .inProgress, text: "IN PROGRESS")
        StatusBadge(status: .success, text: "SUCCESS")
        StatusBadge(status: .failed, text: "FAILED")
        StatusBadge(status: .queued, text: "QUEUED")
    }.padding()
}
#Preview("BranchTagPill") {
    VStack(spacing: 8) {
        BranchTagPill(name: "feat/redesign-phases-1-5")
        BranchTagPill(name: "main")
    }.padding()
}
#Preview("CardRowModifier") {
    VStack(spacing: 8) {
        Text("Standard row").padding().cardRow()
        Text("Elevated row").padding().cardRow(elevated: true)
    }.padding()
}
#endif
