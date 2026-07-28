// PanelContent.swift
// MenuBarKit
//
// The SwiftUI side of the sizing pipeline, and the panel's chrome.
//
// HOW SIZING WORKS — read this before touching anything here:
//
// 1. `MBKHostingView` is configured with `sizingOptions = [.intrinsicContentSize]`
//    AND `translatesAutoresizingMaskIntoConstraints = false`, and the controller
//    pins it edge-to-edge to the window's content view with four required
//    constraints. BOTH halves are load-bearing: per the AppKit header,
//    `NSHostingView` only creates — and only keeps invalidating — its
//    intrinsic-content-size constraints "when Auto Layout constraints are
//    otherwise being used in the containing window". With the old
//    autoresizing-mask layout there was no Auto Layout in the window at all, so
//    `invalidateIntrinsicContentSize()` never fired a second time and the window
//    froze at whatever size the first measurement produced.
//    ❌ NEVER set `translatesAutoresizingMaskIntoConstraints = true` here again.
// 2. AppKit therefore asks SwiftUI for the root's size under an *unspecified*
//    proposal. The root is `MBKPanelContentView`: the adopter's content, capped
//    in height, inset by the arrow, clipped to the bubble. Its ideal size is
//    exactly the window size — content plus the arrow strip.
// 3. `MBKPanelController` subtracts the arrow strip, clamps, and turns the result
//    into a window frame. Resizing the *window* resizes the pinned hosting view,
//    so SwiftUI re-proposes exactly that size to the content and a `ScrollView`
//    inside receives the capped height and scrolls instead of overflowing.
// 4. The second pass measures the same value, so the loop converges after one
//    round trip. The coalescer's 1pt dedupe absorbs float noise.
//
// ❌ NEVER put a min/max *width* in this wrapper. It applies to every route the
//    adopter shows, so a fixed-width settings screen would be stretched to the
//    list's minimum width. Width belongs to the adopter's own views; MenuBarKit
//    caps only the height (the live screen fraction) and the screen width.
// ❌ NEVER add `.fixedSize()` in this wrapper. It would make the content ignore
//    the concrete proposal in step 3, and every capped scroll view would
//    overflow the panel instead of scrolling — that is exactly the class of bug
//    #2278/#2279 were about.
// ❌ NEVER measure with a `GeometryReader`. A geometry reader sees the size we
//    already applied, not the size the content wants, so it cannot detect growth.
// ❌ NEVER apply `.glassEffect(...)` in this wrapper. Glass cannot sample other
//    glass: a SwiftUI glass ancestor silently flattens every
//    `GlassEffectContainer` in the adopter's content. The bubble is drawn by
//    `MBKPanelChromeView` at the AppKit layer, below this hosting view, exactly
//    the way `NSPopover` used to layer its chrome under the hosted content.
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
    ///
    /// Written by `applyFrame(content:reason:)` from `MBKPanelGeometry.layout`.
    /// The controller is the only writer; the bubble shape is the only reader.
    var arrowCenterX: CGFloat

    /// Creates a limits object.
    /// - Parameters:
    ///   - maxContentHeight: Maximum content height in points.
    ///   - arrowCenterX: Initial arrow centre in window-local points.
    init(maxContentHeight: CGFloat, arrowCenterX: CGFloat) {
        self.maxContentHeight = maxContentHeight
        self.arrowCenterX = arrowCenterX
    }
}

// MARK: - Root view

/// Root SwiftUI view of the panel: the adopter's content, clipped to the bubble.
///
/// The bubble *material* is not here — it is `MBKPanelChromeView`, an AppKit
/// `NSGlassEffectView` pair sitting below this view in the same window. This
/// view only positions and clips, so the adopter's own Liquid Glass renders
/// with no glass ancestor above it.
struct MBKPanelContentView: View {

    /// Live sizing limits and arrow position.
    let limits: MBKPanelLimits

    /// Chrome metrics — arrow size and corner radius.
    let metrics: MBKPanelMetrics

    /// The adopter's content.
    let content: AnyView

    /// The current bubble silhouette, tracking the live arrow position.
    ///
    /// Used for clipping only. The same `arrowCenterX` drives
    /// `MBKPanelChromeView`, so the clip and the AppKit glass always agree.
    private var bubble: MBKBubbleShape {
        MBKBubbleShape(
            arrowCenterX: limits.arrowCenterX,
            arrowHeight: metrics.arrowHeight,
            arrowWidth: metrics.arrowWidth,
            cornerRadius: metrics.cornerRadius
        )
    }

    /// Caps the content height, insets it below the arrow, and clips to the bubble.
    ///
    /// Order matters: the cap applies to the content alone, the arrow inset is
    /// added on top of it, and the clip uses the *padded* bounds so the
    /// silhouette and the window frame describe the same rectangle.
    var body: some View {
        content
            .frame(maxHeight: limits.maxContentHeight)
            .padding(.top, metrics.arrowHeight)
            .clipShape(bubble)
    }
}

// MARK: - Hosting view

/// `NSHostingView` that tells the controller when the hosted size may have changed.
///
/// Two independent signals, deliberately:
/// - `invalidateIntrinsicContentSize()` — AppKit's own "the ideal size is stale"
///   notification. This is the fast path.
/// - `layout()` — fires on every layout pass. The controller re-measures and only
///   acts when the number actually moved. This is the safety net: if the
///   intrinsic invalidation ever stops arriving, the window still tracks content.
final class MBKHostingView: NSHostingView<MBKPanelContentView> {

    /// Called on the main actor when the intrinsic content size may have changed.
    var onIntrinsicSizeChange: (@MainActor () -> Void)?

    /// Called on the main actor at the end of every layout pass.
    var onLayoutPass: (@MainActor () -> Void)?

    /// Creates the hosting view.
    ///
    /// `translatesAutoresizingMaskIntoConstraints = false` is required, not
    /// stylistic — see the sizing notes at the top of this file. Hugging and
    /// compression resistance are dropped to `.defaultLow` so the controller's
    /// required edge pins always win over the intrinsic-size constraints AppKit
    /// derives from the SwiftUI content; the window drives the size, the content
    /// only reports what it would like.
    /// - Parameter rootView: The panel root view.
    required init(rootView: MBKPanelContentView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .vertical)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        // NSHostingView draws a solid system background by default. Make it
        // fully transparent so the AppKit glass chrome below shows through.
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    /// Not supported — the panel is built in code.
    /// - Parameter coder: Unused.
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Forwards AppKit's invalidation to the controller.
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIntrinsicSizeChange?()
    }

    /// Forwards the end of every layout pass to the controller.
    override func layout() {
        super.layout()
        onLayoutPass?()
    }
}
